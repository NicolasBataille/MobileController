# agent-device pitfalls — Symptom → Cause → Workaround

Pinned: **agent-device 0.20.10 / Xcode 26.6 / iOS 26.5**. Every entry was observed on a real
simulator during the bake-off unless tagged `(unverified)`. Syntax: `agent-device-cheatsheet.md`.

## 1. REAPER GUARD — never `pkill` anything agent-device started
**Symptom.** After `pkill -f AgentDeviceRunner`, accessibility died **device-wide** on that sim:
`idb ui describe-all` → 1 element, frame 0x0; `axe describe-ui` → same; a third tool → "the
frontmost app exposed an empty accessibility tree". Broken for the app under test **and** for
Settings, i.e. not app-specific. Not fixed by `simctl terminate`+`launch` (x3) nor by
`launchctl kickstart AccessibilityUIServer` ("102: Operation not supported on socket").
**Cause.** `close` deliberately leaves **three** processes alive so the next `open` is ~3 s, not ~30 s:
```
node …/agent-device/dist/src/internal/daemon.js            # host daemon
xcodebuild test-without-building -only-testing AgentDeviceRunnerUITests
…/Devices/<udid>/data/Containers/…AgentDeviceRunner…       # IN-SIMULATOR XCUITest runner
```
SIGTERM to the **in-simulator** runner poisons the sim's accessibility translation layer for every
AX client until the device is restarted. Killing only the host daemon + `xcodebuild` broke nothing.
**Workaround.** Teardown ladder, in order — **no `pkill`, no `kill`, ever**:
```bash
agent-device close --session default              # end session, keep the runner warm
agent-device daemon stop                          # stop the host daemon
agent-device daemon stop --clean                  # + drop retained runner processes and leases
agent-device close --shutdown --session default   # also shut the simulator down
```
`daemon stop --clean` is help-documented ("remove retained runner processes and leases after
stopping") — it is the sanctioned reclaim. The in-sim runner also idle-stops on its own (default
5 min; `AGENT_DEVICE_IOS_RUNNER_IDLE_STOP_MS`, `0` disables).
**Recovery once AX is poisoned: reboot the simulator.** Nothing softer worked.

## 2. `close` succeeds but leaks the device lease
**Symptom.** `close` returns rc 0 (`Closed: default`, 3.6 s); the next plain `open` fails, twice
(12.8 s, 10.8 s): `Error (DEVICE_IN_USE): Device is already in use by session "default".`
**Cause.** `close` ends the session but does not release the host-local device claim. Fixed
upstream after 0.20.10 (#2057); on 0.20.10 use the workaround below.
**Workaround.** Reopen under the same explicit session (succeeded in 6.8 s), and keep passing it —
a bare `snapshot` afterwards fails `SESSION_NOT_FOUND`:
```bash
agent-device open com.example.app --platform ios --session default
agent-device snapshot -i --session default
```

## 3. Implicit session names are a cwd hash and coexist with `--session`
**Symptom.** `open --session default` works, then a bare `snapshot` fails `SESSION_NOT_FOUND`.
Two sessions sit side by side: `~/.agent-device/sessions/default` and
`~/.agent-device/sessions/cwd_<16-hex>_default`.
**Cause.** With no `--session`, the name is derived from the working directory, so a command run
from a different cwd — or without the flag after one with it — lands in a different session and
disagrees about device state.
**Workaround.** Pass `--session <name>` on **every** command, or export `AGENT_DEVICE_SESSION`
once for the shell. `agent-device session list` shows what exists before you debug anything else.

## 4. `--device` takes a name; `--udid` takes a UDID
**Symptom.** `--device <a-udid-string>` → `DEVICE_NOT_FOUND`, with no hint that `--udid` exists.
**Cause.** `--device <name>` is "Device name to target"; `--udid <udid>` is "iOS device UDID".
`--udid` is missing from the `help commands` Global Flags block (it appears in `help device` usage
and the CLI flag schema), so it is easy to miss.
**Workaround.** Resolve name → UDID (`simprobe devices --json`, or `agent-device devices`) and pin
with `--udid`. Names collide constantly — several local simulators are called "iPhone 17".
Live `--udid` pinning **works** (verified on 0.20.10, three simulators booted, two of them
iOS 26.5 iPhones): `agent-device --udid <udid> --session <name> open com.apple.Preferences`
opened on the pinned device and `snapshot -i` returned that device's tree; `xcrun simctl spawn
<udid> launchctl list` confirmed the app was running on it and not on its sibling. No fallback
is needed. `--udid` still does not appear in the `help commands` Global Flags block, so it
remains easy to miss.

## 5. AZERTY / non-QWERTY: `fill` yes, HID keycodes no
**Symptom.** HID-keycode text entry on an AZERTY-French sim corrupts silently — `example.com` read
back as `Exq,ple:co,`. A select-all via `key-combo` Cmd+HID('a') sent **Cmd+Q** and quit the app.
**Cause.** Those tools (sim-use / idb / AXe) map characters to raw HID keycodes ignoring the active
layout; HID `a` is physically `q` on AZERTY. agent-device ships **no** `key`/`key-combo` primitive
at all — this is a hazard you import by reaching for another tool.
**Workaround.** `agent-device fill <@ref|selector> <text>` — XCUITest `typeText`, layout
independent, verified verbatim (`"value": "example.com"`) on an AZERTY sim. `type` (append) uses
the same runner but is **`(unverified)`** on AZERTY — prefer `fill`. Never shell out to a keycode
tool to work around a missing agent-device primitive.

## 6. No clear-field primitive
**Symptom.** `fill @e57 ""` → `Error (INVALID_ARGS): Expected text to be a non-empty string.`
`get value @e57` → `Error (INVALID_ARGS): get only supports text or attrs`.
**Cause.** `fill` replaces a value but refuses an empty one, and `keyboard` offers only
`status|get|dismiss|enter|return` — there is no delete/backspace verb.
**Workaround,** in order of preference:
1. If the field just needs a **different** value: `fill @ref "<new value>"` — it replaces.
2. Tap the app's own clear button (measured, works): `press @<clearButton> --settle`.
3. Clear to empty via the on-screen keyboard — flags are help-verified, end-to-end
   **`(unverified)`**. The keyboard is exposed as AX elements, so the delete key has a ref, but its
   label is **locale-dependent** (`"supprimer"` on a French sim): read it from the snapshot.
```bash
agent-device get attrs @e57      # -> {"value":"example.com", …}  => 11 chars
agent-device snapshot -i         # -> @e38 [key] "supprimer"
agent-device press @e38 --count 11 --settle
```

## 7. `batch` step shape is undocumented, not the verb set
**Symptom.** Object-shaped steps written the obvious way fail: `unknown legacy field(s):
args|target|argv`. `help batch` and the error text never say what a step should look like, so this
reads as "press/fill/click aren't batchable."
**Cause.** Step shape, not an exclusion. `press`/`click`/`fill`/`longpress`/`scroll`/`back` are all
`batchable: true` (already true at 0.20.10) — nothing was ever lifted. Each step must be
`{"command":"<name>","input":{...}}`, where `input` is exactly the input object that command takes
on its own; there is no positional/legacy form ([#2062](https://github.com/callstack/agent-device/issues/2062)).
**Workaround.** Use the shape above:
```bash
agent-device batch --steps '[{"command":"press","input":{"target":{"kind":"selector","selector":"id=\"tabBar.list\""}}},{"command":"snapshot","input":{"interactiveOnly":true}}]'
```
Use selectors, not `@ref` targets, for any step after the first mutation — a second mutating step
addressed by `@ref` fails `ref_frame_expired` because the first step invalidates the ref frame.

## 8. Host load produces hard failures, not slowdowns
**Symptom.** `fill …` → `Error (COMMAND_FAILED): main thread execution timed out` after ~50 s at
loadavg ≈ 200. The identical command took 2.6 s once load dropped. Cold `open` ranged 12 s → 33 s.
**Cause.** The XCUITest runner shares the host CPU with everything else; there is no backpressure,
just a main-thread timeout.
**Workaround.** Read `uptime` / loadavg **before** blaming the tool or the app. Above ~50 on 8
cores, treat wall-clock numbers as meaningless and timeouts as environmental: quiesce the host,
retry the identical command. Do not "fix" a load failure by adding flags.

## 9. Refs go stale after any mutation
**Symptom.** `Error (COMMAND_FAILED): Ref @e11 belongs to an expired ref frame — a device action
since the snapshot invalidated it`.
**Cause.** Refs belong to the snapshot frame that issued them; any device action invalidates it.
This is a feature — the alternative, silently acting on whatever the ref now points at, is how
other tools tap the wrong element.
**Workaround.** Re-observe, then act. The cheapest re-observation is the diff you already have:
`press … --settle` returns the settled diff with fresh refs, so continue from that instead of
re-snapshotting. Copy refs verbatim, `~sN` pin included (`@e12~s698558`).

## 10. `--settle` is not free
**Symptom.** A `press` costing ~1.0–1.5 s bare costs 1.5–3.4 s with `--settle`, and returns
~1.9–2.2 KB instead of ~37 B.
**Cause.** `--settle` waits for the UI to go quiet (`--settle-quiet`, default 500 ms; deadline
`--timeout`, default 10 s) and returns the full diff vs the pre-action tree.
**Workaround.** Use `--settle` only when the diff **is** the verification; when the next step
re-observes anyway, press bare. `--verify` is the cheap middle ground (AX digest + node counts +
`changedFromBefore`, ~37 B, 1.1–1.3 s). `--settle` is rejected on `open`, `snapshot`, `close`, `type`.

## 11. An AX-quiet tree is not a settled screen
**Symptom.** `wait stable` returns while the screen is still visibly animating (implicit SwiftUI
animation, crossfade, Canvas/Lottie view with no AX identity).
**Cause.** It measures accessibility-tree quiescence, not pixels, and needs an open session.
**Workaround.** Use `simprobe wait-stable` / `simprobe motion` for rendering questions — `simprobe.md`.

## 12. A slept simulator display screenshots as solid black
**Symptom.** After a few minutes idle, `xcrun simctl io <udid> screenshot` returns a frame that is
entirely black while `agent-device snapshot` still returns the full, correct AX tree. Every pixel
measurement then agrees that the screen is perfectly settled: `simprobe wait-stable` reports
`stable`, `simprobe motion` reports a timeline of `0.00`, and nothing anywhere reports a failure.
**Cause.** The simulator auto-locks and the framebuffer goes dark. The accessibility tree is
unaffected, so an AX-only tool cannot see the difference either — the two layers disagree, and only
the pixel layer is wrong.
**Workaround.** Wake with a HID event before any pixel measurement — `idb ui button HOME --udid
<udid>` or `idb ui tap --udid <udid> <x> <y>`; `xcrun simctl launch` and `openurl` do **not** wake
it. For a long run, set Auto-Lock to Never in Settings ▸ Display & Brightness. Guard the
measurement itself: a capture whose thumbnail has fewer than ~8 distinct tones is a blank frame,
not a settled screen (`LiveSmokeTests.testLiveCaptureIsNotBlank`).

## 13. A lazily decoded screenshot goes black when its file is deleted
**Symptom.** A capture pipeline that writes `simctl io … screenshot` to a temporary file, decodes
it, and removes the file in a `defer` hands back a `CGImage` that draws as solid black. The PNG on
disk is 2.9 MB of real content; the JPEG re-encoded from the decoded image is 6.7 KB of nothing.
**Cause.** `CGImageSourceCreateWithURL` decodes **lazily**. The returned `CGImage` keeps referring
to the file, so every later `CGContext.draw` reads a file that no longer exists — and returns black
rather than an error.
**Workaround.** Decode from the file's bytes, not from its URL: `Data(contentsOf:)` then
`CGImageSourceCreateWithData`. This is what `simprobe`'s `ImageDecoder` does, and the regression
test deletes the file before measuring (`AdapterTests.testCaptureSurvivesRemovalOfTheTemporaryFile`).
Symptom 12 and this one look identical from the outside; distinguish them by checking the PNG on
disk before it is removed.
