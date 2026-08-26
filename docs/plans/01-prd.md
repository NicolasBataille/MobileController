# MobileController — PRD (v1)

Status: approved plan, pre-implementation. Last updated 2026-08-26.

## 1. Problem

A Claude Code agent asked to "check that the new sheet animates in and the email field
accepts input" on an iOS Simulator has no good way to do it. Measured across seven existing
tools, the same screen costs between 78 and 96,873 tokens to observe — a 1,240x spread —
while latency varies only 3x (0.36–1.4 s). **Observation tokens, not latency, are the
dominant cost.** Secondary failures found in measurement:

- The accessibility tree is **silently truncated during animation** (1–20 nodes instead of
  the settled 42), returning fast and wrong rather than slow.
- HID-keycode text entry is **corrupted on non-QWERTY simulators** (`example.com` →
  `Exq,ple:co,`), and the usual select-all workaround sends Cmd+Q on AZERTY, quitting the app.
- No tool answers "did the animation finish, and did it actually move?" **without sending
  images** to the model.
- Full-resolution screenshots cost ~4,200 vision tokens each; the same screen at 1x logical
  points costs ~470.

## 2. Users

- **Primary: a Claude Code agent** driving a simulator through Bash. It needs a small,
  stable command vocabulary, output measured in hundreds of bytes, and loud failures.
- **Secondary: the iOS developer** running that agent. They need a one-command install, no
  private-API risk on their machine, and a benchmark they can re-run to check regressions
  after an Xcode update.

## 3. Decision (settled, not re-opened here)

Adopt **agent-device** (callstack, MIT, v0.20.10) as the automation engine, used **strictly
as a CLI invoked from Bash — never as an MCP server** (MCP costs 3k–66k tokens of tool
schemas on every sampling; a CLI costs 0 standing tokens). MobileController does not
reimplement device automation. It ships the three things agent-device does not provide.

## 4. Goals

- G1 — Make a full observe→act→verify cycle cost **≤ 600 bytes** of agent-visible output on
  a dense screen, by encoding an escalation ladder instead of defaulting to the full tree.
- G2 — Answer "is the screen settled / did it animate" with a **numeric** signal and **zero
  images returned**.
- G3 — Zero private APIs, zero Python, zero codesigning story. `swift build` and go.
- G4 — Make every claim in this repo reproducible by a script a third party can run.

## 5. Non-goals (v1)

- Not a device-automation engine. No AX tree reading, no HID, no XCUITest of our own.
- No MCP server. Ever, for the observation path.
- No physical devices, no Android, no web. iOS Simulator only.
- No warm action daemon (see Future work), no frames overlay, no batched press sequences.

### Why a `wait-stable` at all when `agent-device wait stable` exists

Verified in 0.20.10: `wait <ms>|text|@ref|<selector>|stable [quietMs] [timeoutMs]` exists.
It is not a substitute, for three reasons:

1. It measures **accessibility-tree** quiescence. A tree can be quiet while pixels are still
   moving (implicit SwiftUI animation, a crossfade, a Lottie/Canvas view with no AX identity).
   Rendering questions need a rendering answer.
2. It requires an **open session** — daemon + `xcodebuild test-without-building` + an
   in-simulator runner. `simprobe wait-stable` needs only `xcrun simctl`, so it works before
   a session exists, after one dies, and in teardown.
3. The bench needs an **independent control probe** to attribute latency. A timer that lives
   inside the tool being measured cannot serve as that control.

## 6. Measured baseline → acceptance targets

All figures measured on this class of machine (Xcode 26.6, iOS 26.5, Apple silicon) against a
dense production SwiftUI screen (60 nodes, 43 interactive). Bytes → tokens estimated at /4.

| Observation form | Bytes | ~Tokens | Warm latency |
|---|---:|---:|---:|
| `snapshot` (full tree) | 2,266 | ~570 | 580–1,580 ms |
| `snapshot -i` (interactive only) | 1,295 | ~325 | 450–540 ms |
| `snapshot -i --level digest` | 510 | ~128 | ~450 ms |
| `screenshot` (402x874 @1x PNG) | 172,078 | **468 vision** | ~1,130 ms |
| Reference tool, default outline | 2,380 | ~595 | 5–12 s |
| Reference tool, full-res PNG | 2,352,036 | **4,216 vision** | ~2–3 s |

| Action | Latency |
|---|---:|
| `press <id>` bare | ~1,530 ms |
| `press … --settle` (waits for quiet, returns the diff) | 1,500–3,400 ms |
| `xcrun simctl io … screenshot` (capture floor) | ~200 ms (~3.5 fps burst) |

Stability signal, measured: downscale to 40x87 grayscale, mean-absolute-difference between
consecutive frames. Idle screen carrying a perpetual micro-animation = **0.00–0.03**. Real
screen transition = **11.01**. A threshold of 0.5 separates them by ~350x. Exact-hash equality
does **not** work: a screen with a micro-animation never produces two identical frames
(measured 12/12 distinct, 21 polls, 4.1 s timeout, no answer).

### Acceptance targets for v1

- **A1** — A 30-action agent session using the documented ladder emits **≤ 5,000 tokens** of
  observation (measured: 4,200 with digest; 9,900 with `-i`; 18,400 for the best alternative).
- **A2** — `simprobe wait-stable` returns in **≤ 400 ms** on an already-settled screen and
  reports settled within **≤ 400 ms** of the true end of a standard 300 ms transition.
- **A3** — `simprobe motion` returns a diff timeline with **0 bytes of image data** on stdout.
- **A4** — `simprobe shot` output is **≤ 500 vision tokens** and at exactly 1x logical points,
  so coordinates read off the image map 1:1 onto the accessibility frame.
- **A5** — `swift test` passes on a GitHub Actions macOS runner **with no simulator booted**
  (simulator-dependent tests skip, not fail).
- **A6** — `swift test` coverage ≥ 80% on the core library.

## 7. v1 scope

### (a) Claude Code skill — `skill/SKILL.md` + short reference files

Encodes the conventions, so the agent does not rediscover them per session:

- **Observation escalation ladder.** Start at `snapshot -i --level digest` (~510 B). Escalate
  to `snapshot -i` (~1.3 KB) only when the digest lacks the target. Escalate to the full tree
  (~2.3 KB) only for structure questions. Take a screenshot (~468 vision tokens) only for
  rendering questions the tree cannot answer.
- **Re-observation short-circuit.** When re-observing a screen already seen this session, use
  `snapshot --diff` / `diff snapshot` instead of a fresh snapshot: it emits only what changed,
  and `press … --settle` already returns that diff for free.
- **Settle decision rule.** Bare `press` (~1.5 s) when the next step re-observes anyway;
  `press … --settle` (1.5–3.4 s, quiet window 500 ms, timeout 10 s by default) when the diff
  it returns *is* the verification. `simprobe wait-stable`/`motion` for rendering-level
  questions and for teardown-time checks.
- **Text entry.** Always `fill` (XCUITest `typeText`, layout-independent — verified verbatim
  on an AZERTY simulator). **Never** HID `type`/keycodes for real text.
- **Field clear recipe.** No clear primitive exists (`fill @ref ""` → `INVALID_ARGS: Expected
  text to be a non-empty string`). Read the value's length via `get`, send that many delete
  keys. **Never** letter keycodes or a select-all `key-combo`: on AZERTY, Cmd+HID('a') is
  **Cmd+Q** and quits the app under test.
- **Launch with fixtures.** `open <bundle> --launch-args <arg>` (repeatable, forwarded
  verbatim) instead of a separate `simctl launch`.
- **Session hygiene.** Always pass an explicit `--session`. The implicit session name is a
  **cwd hash**, so an implicit session and `--session default` coexist and disagree. `close`
  reports success but **leaks the device lease** — the next `open` fails `DEVICE_IN_USE`;
  reopen with the same explicit `--session`.
- **Device pinning.** `--device` matches by **name only**; several local simulators commonly
  share a name. `--udid <udid>` exists in 0.20.10's selection-flag table — pin with it, and
  resolve name→UDID with `simprobe devices --json`.
- **REAPER GUARD.** After `close`, three processes stay alive **by design**: the node daemon,
  `xcodebuild test-without-building`, and an in-simulator `AgentDeviceRunner`. `pkill`-ing the
  in-simulator runner **poisons accessibility device-wide for every tool on that simulator
  until reboot** (reproduced: `describe-all` then returns 1 element, frame 0x0, for every app).
  Teardown is `close`, then `daemon stop` if resources must be released. Never `pkill`.
- Pinned compatibility: **agent-device 0.20.10 / Xcode 26.6 / iOS 26.5**.

### (b) `simprobe` — a probe CLI in Swift

SwiftPM, single binary, macOS 14+, **no private APIs**. Subprocesses `xcrun simctl io <udid>
screenshot` and analyses the result with CoreGraphics/ImageIO. Verbs: `wait-stable`, `motion`,
`shot`, `devices`, `diff`. Each has a compact human-readable default and `--json`. Full
signatures and output samples in `02-architecture.md`.

### (c) `bench/` — a reproducible benchmark harness

Runs a fixed observe→act→observe flow and records, per row: wall-clock, stdout bytes,
estimated tokens (bytes/4), **host loadavg**, and a **`simctl` screenshot control-probe time**.
Host load swung 5→450 during the bake-off and inflated wall-clock by 2–10x; a benchmark that
hides that is worse than none. Emits CSV plus a markdown table. Targets are Apple Settings
(`com.apple.Preferences`, zero setup) or the bundled `DemoApp/` — never a private app.

## 8. Success criteria

1. A fresh clone reaches a green `swift test` in one command, with no simulator booted.
2. `bench/run.sh` produces a CSV and a markdown table on a stock machine against Settings.
3. The skill, dropped into `~/.claude/skills/`, lets an agent complete a scripted
   observe→act→verify flow within the A1 token budget, with no field-clear or AZERTY incident.
4. Every number published in the README is regenerable by a committed script.

## 9. Risks

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| R1 | An Xcode/iOS update breaks agent-device's XCUITest runner. | High | Pin the tested triple in the skill header; `bench/` doubles as the canary; `simprobe` depends only on `simctl` and keeps working. |
| R2 | Host load inflates every measurement 2–10x, silently. | High | loadavg + control-probe columns are **mandatory** in every bench row; the README states the ratio, not the absolute. |
| R3 | A CI runner or a crashed agent reaps the in-simulator runner and poisons AX device-wide until reboot. | High | REAPER GUARD in the skill *and* in every bench teardown path; no `pkill` anywhere in the repo; documented recovery = reboot the simulator. |
| R4 | The 0.5 stability threshold is empirical and may not fit every app. | Medium | `--tol` is a flag, the default is documented with its measured separation (0.03 vs 11.01), and `motion` prints the raw timeline so a user can pick their own. |
| R5 | `--udid` pinning is inferred from the flag table, not yet exercised. | Medium | Phase-2 task verifies it against a live simulator; documented fallback is name + a snapshot-content assertion before acting. |
| R6 | Someone adds a private-API shortcut later and breaks the "no private APIs" promise. | Medium | Stated as a project invariant here; CI greps for `dlopen`/`AXPTranslator`/`SimulatorKit` and fails the build. |
| R7 | Public-repo leakage of personal paths, UDIDs, or a private app's identifiers. | High | Phase-5 sanitizer pass with a committed grep list; user-specific config lives only in a git-ignored file or env vars. |

## 10. Future work (README section, not v1)

- Warm **idb-gRPC action daemon** — 20 ms taps, 51–72 ms trees measured, ~6x latency win.
- **Frames overlay** from `idb ui describe-all` — agent-device snapshots carry no coordinates.
- **Batched press sequences** — `batch` currently rejects `press`/`fill`; file upstream.
- **Pluggable backends** behind the skill's vocabulary.

### Upstream issues to file on agent-device

1. `close` reports success but does not release the device lease → next `open` fails
   `DEVICE_IN_USE`.
2. `batch` excludes `press`/`fill`/`click`: "Batch step 1 command is not available through
   command batch: press".
3. `fill @ref ""` rejected with `INVALID_ARGS` — no clear-field primitive exists.
4. `--device <name>` on a UDID fails `DEVICE_NOT_FOUND` without hinting at `--udid`, which is
   itself absent from the global-flags help.
5. The implicit cwd-hash session name coexisting with an explicit `--session` is a footgun;
   consider warning when both exist for one device.
