# agent-device 0.20.10 — cheatsheet

Pinned: **agent-device 0.20.10 / Xcode 26.6 / iOS 26.5**. Every flag below was read from
`agent-device help` / `agent-device help <command>` at 0.20.10. Anything not in help output is
tagged `(unverified)`. Failure modes live in `pitfalls.md` — read it before your first `open`.

## Selection + global flags

Selection flags are **not** listed under "Global Flags" in `help commands`; they appear in the
CLI flag schema and verbatim in `help device` / `help doctor` hints.

| Flag | Meaning |
|---|---|
| `--platform ios\|android\|web\|macos\|…` | Platform to target (`apple` aliases the Apple backend) |
| `--device <name>` | Device **name** to target — never a UDID (see pitfalls) |
| `--udid <udid>` | iOS device UDID. Shown in `help device` usage; live pinning `(unverified)` |
| `--serial <serial>` | Android / Vega serial |
| `--session <name>` | Named session. **Always pass it explicitly** |
| `--level digest\|default\|full` | Response detail. `digest` = token-cheap. **Global**, not a `snapshot` flag |
| `--json` | JSON output |
| `--cost` | Add per-command wall clock as `cost.wallClockMs` |
| `--config <path>` / `--debug, -v` | Config file / debug diagnostics |

## Commands

| Command | Syntax + the flags worth using |
|---|---|
| `open` | `open [appOrUrl] [url]` · `--launch-args <arg>` (**repeatable**, forwarded verbatim to the iOS launch) · `--relaunch` (terminate first) · `--foreground` (keep selection, return initial snapshot) · `--launch-console <path>` · `--device-hub` · `--save-script [path]` |
| `snapshot` | `snapshot [--diff] [-i] [-d <depth>] [-s <scope>] [--raw] [--actions] [--force-full] [--timeout <ms>]`. `-i` = interactive only; `--diff` = structural diff vs the session baseline; `-s` scopes to a label/identifier |
| `press` | `press <x y|@ref|selector>` · `--settle` · `--settle-quiet <ms>` (default 500) · `--timeout <ms>` (settle deadline, default 10 s) · `--count <n>` · `--interval-ms <ms>` · `--hold-ms <ms>` · `--double-tap` · `--verify` (cheap AX digest + `changedFromBefore` instead of a follow-up snapshot) |
| `fill` | `fill <x> <y> <text>` \| `fill <@ref|selector> <text>` — **replaces** the value. `--settle`, `--delay-ms <ms>`, `--record-as <VAR>`. XCUITest `typeText`; layout-independent (AZERTY verified) |
| `type` | `type <text> [--delay-ms <ms>]` — **appends** after focus. Never accepts `--settle` |
| `longpress` | `longpress <x y|@ref|selector> [durationMs]` — duration is **positional**, not `--hold-ms`. `--settle` |
| `scroll` | `scroll <direction|top|bottom> [amount] [--pixels <n>] [--duration-ms <ms>] [--settle]` |
| `back` | `back [--in-app|--system] [--settle]` |
| `wait` | `wait <ms>|text <text>|@ref|<selector>|stable [quietMs] [timeoutMs]` — `stable` = AX-tree quiescence only |
| `is` | `is <predicate> <selector> [value]` — visible, hidden, editable, selected, focused, text |
| `get` | `get text|attrs <@ref|selector>` — `attrs` returns the attribute map incl. `value` and `rect`. Only `text`\|`attrs` exist |
| `find` | `find <locator|text> <action> [value] [--first|--last]` — contains-matching, then act |
| `screenshot` | `screenshot [path] [--out <path>] [--overlay-refs] [--pixel-density <n>] [--scale <0.01-1>] [--normalize-status-bar] [--no-stabilize] [--fullscreen]`. iOS sim defaults to **1x logical points** |
| `diff` | `diff snapshot` \| `diff screenshot --baseline <path> [current.png] [--out <diff.png>] [--threshold <0-1>] [--overlay-refs]`. `diff snapshot` accepts `-i`/`-d`/`-s` |
| `session` | `session list` \| `session state-dir` \| `session save-script [path] [--force]` |
| `close` | `close [app] [--shutdown] [--save-script [path]] [--force]` — `--shutdown` also stops the simulator |
| `daemon` | `daemon stop [--state-dir <path>] [--clean]` — `--clean` removes **retained Apple runner processes and leases** owned by that daemon. This is the sanctioned deep teardown |
| `batch` | `batch [--steps <json>|--steps-file <path>] [--on-error stop] [--max-steps <n>] [--out <path>]` — steps are `{"command":"<name>","input":{...}}`; `press`/`fill`/`click` **are** batchable (pitfalls) |
| `devices` | `devices` — lists selectable devices/simulators; feed the result to `--platform/--device/--udid/--serial` |

Other verbs worth knowing: `apps`, `appstate`, `boot`, `shutdown`, `install`, `home`,
`app-switcher`, `alert`, `keyboard [status|get|dismiss|enter|return]`, `clipboard read|write`,
`focus <x> <y>`, `gesture`, `swipe`, `orientation`, `record`, `logs`, `network`, `perf`,
`capabilities`, `doctor`, `device status`. Full list: `agent-device help commands`.

## Output shapes (measured; app names anonymised)

```
$ agent-device snapshot -i                          # 1295 B, ~450 ms warm
Page: com.example.app
App: com.example.app
Snapshot: 49 nodes
@e1 [application] "TestApp"
@e12 [button] "Start" #home.startButton
```
```
$ agent-device press id=tabBar.settings              # 37 B, ~1.5 s
Tapped id=tabBar.settings (85, 841)
```
```
$ agent-device press id=tabBar.settings --settle     # ~1.9 KB, 1.5-3.4 s
Tapped id=tabBar.settings (85, 841)
settled after 469ms: +9 -38 (~4 unchanged)
- @e4 [text] "Preferences"
+ @e57~s698558 [text-field] "example.com"
```
```
$ agent-device fill @e14 "example.com" --settle      # "Filled 11 chars" + the same diff block
$ agent-device scroll down --settle                  # "Scrolled down by 400" + diff
$ agent-device back --settle                         # "Back" + diff
$ agent-device close --session default               # "Closed: default"  (16 B)
$ agent-device screenshot --out shot.png             # "shot.png (420x912 @1x)"
```
```
$ agent-device get attrs @e57                        # 294 B
{ "ref": "e57", "type": "TextField", "value": "example.com",
  "rect": {"x":56,"y":210,"width":308,"height":20}, "enabled": true, "hittable": false, … }
```
```
$ agent-device snapshot -i --level digest --json     # 510 B  (exact flag combo reconstructed)
{ "nodeCount": 46, "refs": [ {"ref":"e1","label":"TestApp"}, {"ref":"e44","label":"Study"}, … ] }
```
Refs carry an optional pin: `@e12~s698558`. Copy refs **verbatim**, `~sN` included.

## Measured cost (dense SwiftUI screen, 60 nodes / 43 interactive; bytes ÷ 4 ≈ tokens)

| Call | Bytes | ~Tok | Warm ms |
|---|---:|---:|---:|
| `snapshot` (full) | 2266 | 570 | 580–1577 |
| `snapshot -i` | 1295 | 325 | 451–542 |
| `snapshot -i --level digest --json` | 510 | 128 | 446 |
| `snapshot --diff` (unchanged screen) | 1373 | 343 | ~315 |
| `screenshot` (420x912 @1x PNG) | 27 (path line) | — | 712–1127 |
| PNG itself: 172 078 B → **~468 vision tokens** | | | |
| `press <id>` bare | 35–37 | ~9 | 856–1527 |
| `press --verify` | 35–37 | ~9 | 1053–1257 |
| `press --settle` | 1919–2153 | ~500 | 1514–3394 |
| `fill --settle` | 1232 | 308 | 4790 |
| `get attrs` | 294 | 74 | ~100 |
| `open` cold | 102–1519 | — | 12 164–33 064 (load-dependent) |
| `close` | 16 | — | 3603 |

10 observe→act pairs: `-i` + `press` = 21.5 s / 13 216 B; `--level digest` + `press` = 5590 B.
30-action projection: `-i` ≈ 9 900 tok, digest ≈ 4 200 tok.
**All wall-clock figures inflate 2–10x under host load — read loadavg before trusting them.**

## Environment variables

Documented in `agent-device help commands`:

| Var | Meaning |
|---|---|
| `AGENT_DEVICE_SESSION` | Explicit session name (same as `--session`) |
| `AGENT_DEVICE_PLATFORM` | Default platform binding |
| `AGENT_DEVICE_SCREENSHOT_SCALE` | Default screenshot scale factor (same as `--scale`) |
| `AGENT_DEVICE_SESSION_LOCK` | Bound-session conflict mode |
| `AGENT_DEVICE_DAEMON_BASE_URL` | Connect to a remote daemon |
| `AGENT_DEVICE_DAEMON_AUTH_TOKEN` | Remote daemon service/API token |
| `AGENT_DEVICE_CLOUD_BASE_URL` | Bridge/control-plane API origin |

Read by the code but not in help output — meanings inferred, all `(unverified)`:

| Var | Inferred meaning |
|---|---|
| `AGENT_DEVICE_CONFIG` | Explicit config-file path (documented under Configuration) |
| `AGENT_DEVICE_STATE_DIR` | Daemon/session state dir (default `~/.agent-device`); cf. `session state-dir` |
| `AGENT_DEVICE_IOS_RUNNER_IDLE_STOP_MS` | In-sim runner idle auto-stop, default 5 min; `0` disables idle stop |
| `AGENT_DEVICE_DAEMON_IDLE_TIMEOUT_MS` | Daemon idle shutdown window |
| `AGENT_DEVICE_MAX_SIMULATOR_LEASES` | Max concurrent simulator leases |
| `AGENT_DEVICE_LEASE_TTL_MS` (+ `_MIN_`/`_MAX_`) | Device-lease time-to-live |
| `AGENT_DEVICE_SCREENSHOT_MAX_SIZE` | Legacy `--max-size`; removed, use `--scale` |
| `AGENT_DEVICE_RETAIN_ARTIFACTS` | Keep daemon artifacts instead of pruning |
| `AGENT_DEVICE_NO_UPDATE_NOTIFIER` | Suppress the npm update banner |
| `AGENT_DEVICE_EXEC_TRACE` | Trace subprocess execution |

`AGENT_DEVICE_RUNNER_*` (≈140 names) are telemetry event labels, not settings — ignore them.
