---
name: mobilecontroller
description: Drive and observe an iOS Simulator from Bash at minimum token cost - inspect a SwiftUI app's screen, tap and fill controls, take a cheap screenshot, and decide whether an animation has finished. Use whenever a task involves an iOS simulator, a SwiftUI or UIKit app under test, an accessibility snapshot, a tap/press/scroll/text-entry action, a simulator screenshot, or "did it animate / is the screen settled". Wraps agent-device (the automation CLI) and simprobe (the pixel-stability probe).
---

# MobileController

Verified against exactly one triple: **agent-device 0.20.10 / Xcode 26.6 / iOS 26.5**. If any
drifts, re-run `bench/run.sh` before trusting a number below. The optional patched build
(`0.20.11-mc.1`, see the README) fixes four limitations noted here: every *rule* holds on both,
the **byte costs do not** — rung 1's digest measured 1515 B there against 447 B on 0.20.10, so
start at rung 2. Check with `agent-device --version`.

Two binaries, both driven from **Bash**. Never as an MCP server.
- `agent-device` — accessibility tree, actions, sessions.
- `simprobe` — pixel-level "is it settled?", 1x screenshots, element coordinates, UDID lookup, and
  a warm action daemon. No session needed. `frames`, `tap` and `tree` need `idb`
  (`brew install facebook/fb/idb-companion && pip3 install fb-idb`); no other verb does.

## 1. Observation escalation ladder

Start at the cheapest rung. Step up **only** when the rung below cannot answer the question.

| Rung | Command | Cost | Use when |
|---|---|---|---|
| 1 | `agent-device snapshot -i --level digest --json` | ≈450 B (~113 tok) at 0.20.10; **≈1.5 KB on the 0.20.11-dev base** (incl. the patched build) — larger than rung 2, start at rung 2 there | Default on 0.20.10. Ref + label of every interactive element. |
| 2 | `agent-device snapshot -i` | ~1.3 KB (~325 tok) | The digest has no ref matching your target. |
| 3 | `agent-device snapshot` | ~2.3 KB (~570 tok) | Structure questions: nesting, containers, non-interactive text. |
| 4 | `simprobe frames --interactive` | ~1.3 KB (~330 tok), 1.5-9 s | **Where** something is. The snapshot has no coordinates at any rung; this is the only rung that gives refs *and* 1x frames. |
| 5 | `simprobe shot --out /tmp/s.jpg` | ~470-510 vision tokens | Rendering questions neither tree nor frame can answer (colour, overlap, actual drawing). |

`--level` is a **global** flag, not a `snapshot` flag. `-i` = interactive nodes only.
**Re-observation short-circuit.** Seen this screen already? `agent-device snapshot --diff` emits
only what changed, and `press … --settle` returns that diff for free — continue from it. One
field: `get attrs @<ref>` (~294 B). One element under a coordinate: `simprobe frames --point x,y`
(~76 B).

Refs expire on any device action. Re-observe, then act. Copy refs verbatim, `~sN` pin included.
## 2. Action rule

| Need | Command | Cost |
|---|---|---|
| Act, next step re-observes anyway | `agent-device press @<ref>` | ~37 B, ~1.0-1.5 s |
| Act, cheap "did anything change" | `agent-device press @<ref> --verify` | ~37 B, ~1.1-1.3 s |
| Act, **the diff is the verification** | `agent-device press @<ref> --settle` | ~1.9-2.2 KB, 1.5-3.4 s |
| Act, then verify **pixels** settled | `agent-device press @<ref>` then `simprobe wait-stable` | ~60 B, +1.5-4 s |

`--settle` waits for AX quiet (`--settle-quiet`, default 500 ms; deadline `--timeout`, default
10 s). AX quiet is **not** pixels quiet: implicit SwiftUI animations, crossfades and Canvas/Lottie
views go quiet in the tree while still moving on screen. For rendering truth use `simprobe
wait-stable` / `motion` — no session, works in teardown, costs four `simctl` captures at 0.2-1.1 s
each. Raise `--timeout` rather than lowering `--tol`.

**Fast action path — for loops, not single steps.** `simprobe daemon start --udid <udid>` holds a
warm idb connection; `simprobe tap <#id|@index|x,y>` then costs **16 ms** and `simprobe tree`
**82 ms**, against ~1.0-1.5 s and ~0.3-0.5 s for `press`/`snapshot -i` — a mixed loop measured
**2.7x faster**, 10/10 correct, with an XCUITest session live on the same simulator. Worth the
1.6 s cold start only when you observe-and-act on one screen many times; `daemon stop` when done.
No session, no `fill`, and a leaner tree: **never diff idb node counts against snapshot counts,
nor use either to prove an element absent.** Verify every tap (`--wait-stable`), as with `press`.

**Text entry: always `fill`.** `agent-device fill @<ref> "text"` uses XCUITest `typeText`:
layout-independent, verified on an AZERTY simulator, and it *replaces* the value. There is **no
clear primitive at 0.20.10** — `fill @ref ""` is rejected; empty a field with the app's own clear
button or `press @<delete-key> --count N` (label is locale-dependent). On the patched build
`fill @ref ""` *is* the clear primitive. See `references/pitfalls.md` §6.

**Reading a value back: `get attrs`, never `get text`/`is text`.** Both resolve to the
accessibility **label** while what the element displays lives in `value`, so `is text @ref
"example.com"` fails against the label and looks like an app bug. Match `value` specifically
(`references/pitfalls.md` §15).

**Launch with fixtures:** `agent-device open com.example.app --launch-args <arg>` — repeatable,
forwarded verbatim. Never `simctl launch` for this.

## 3. Session hygiene

Pass `--udid <udid> --session <name>` on **every** call. With no `--session`, the name is a
**cwd hash**, so an implicit session and `--session default` coexist and disagree. `--device`
matches names **only** and local simulators routinely share a name — resolve with
`simprobe devices --platform ios --json` and pin by UDID.

```bash
UDID=$(simprobe devices --booted --platform ios --json | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["udid"])')
AD="agent-device --platform ios --udid $UDID --session mc"
$AD open com.example.app                # cold 12-33 s, load-dependent
$AD close                               # reports success, but LEAKS the device lease
$AD open com.example.app                # next plain open would fail DEVICE_IN_USE...
                                        # ...reopening under the SAME --session works
```

`--platform ios` is not optional in that recipe: without it the first booted entry can be an
Apple Watch, and every action afterwards lands on the wrong device. With **several** iOS
simulators booted the first entry is merely the newest runtime — assert the target by snapshot
content (or pass the UDID explicitly) before acting on it.

`agent-device session list` filters by the **caller's** scope: a session opened under an explicit
`--session` lists as `{"sessions": []}` from a cwd-scoped shell. Pass the same `--session` to the
listing before concluding nothing is open (`references/pitfalls.md` §14).

**Teardown, in order:** `agent-device close` → `agent-device daemon stop --clean` (the sanctioned
reclaim of runners and leases; add `close --shutdown` to stop the simulator), plus `simprobe
daemon stop` if you started one. `daemon stop --clean` reclaims **every** retained runner owned by
that daemon: if another run shares the host daemon, give yours its own `AGENT_DEVICE_STATE_DIR`.

## 4. The five hard DON'Ts

1. **Never `pkill`/`kill` anything agent-device started.** Three processes survive `close` by
   design (node daemon, `xcodebuild test-without-building`, an in-simulator `AgentDeviceRunner`,
   which idle-stops after ~5 min). SIGTERM to the in-simulator runner **poisons accessibility
   device-wide for every tool until the simulator is rebooted**. Use `daemon stop --clean`.
2. **Never run agent-device as an MCP server.** Tool schemas cost 3k-66k tokens on every
   sampling; the CLI costs zero standing tokens.
3. **Never take a full-resolution screenshot.** `simprobe shot` at 1x costs ~470-510 vision tokens
   (402x874 -> 468, 420x912 -> 510) against ~4,200 at 3x, and its coordinates map 1:1 onto AX
   frames. The number is a property of the screen: read it off the summary line.
4. **Never trust a snapshot taken mid-animation.** The AX tree is silently *truncated* while
   animating — 1-20 nodes instead of the settled 42, returned fast and wrong. Settle first
   (`--settle`, or `simprobe wait-stable`), then snapshot.
5. **Never send HID keycodes or key-combos for text on a non-QWERTY simulator.** agent-device has
   no `key` verb; faking one with another tool corrupts input (`example.com` → `Exq,ple:co,`) and
   Cmd+HID('a') is **Cmd+Q** on AZERTY — it quits the app.

## 5. Worked flow — "does the sheet animate in, and does the field accept input?"

```bash
UDID=<udid>; AD="agent-device --platform ios --udid $UDID --session mc"
$AD open com.example.app --launch-args -uiTesting                 # cold, 12-33 s
$AD snapshot -i --level digest --json                             # rung 1: ~450 B at 0.20.10
$AD press @e12                                                    # bare: ~37 B, ~1.5 s
simprobe motion 1500 --udid "$UDID"                               # did it move, and when did it stop?
$AD snapshot -i --level digest --json                             # fresh refs after the transition
# many steps on one screen instead? simprobe daemon start, then tap/tree, then daemon stop.
$AD fill @e57 "user@example.com" --settle                         # layout-independent; diff is the proof
$AD get attrs @e57                                                # ~294 B: read the value back
simprobe shot --udid "$UDID" --out /tmp/s.jpg                     # ~470-510 vision tokens, only if needed
$AD close
agent-device daemon stop --clean                                  # sanctioned reclaim. NEVER pkill.
```

## 6. References — load on demand

- `references/agent-device-cheatsheet.md` — every verb and flag, output shapes, measured costs,
  environment variables.
- `references/pitfalls.md` — fifteen symptom → cause → workaround entries: REAPER GUARD, the lease
  leak, cwd-hash sessions, AZERTY, field clearing, stale refs, and label-vs-value reads.
- `references/simprobe.md` — every simprobe verb, exit codes, `--json` shapes, the motion timeline,
  the `frames`/`tree` banding and ref format, and the daemon's lifecycle.
