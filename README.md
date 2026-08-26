# MobileController

**Status: v0.1.0 (alpha).** The `simprobe` CLI, the Claude Code skill, the benchmark
harness and the DemoApp are all in place and measured on a real simulator. Expect rough
edges; the pinned tool versions below are the only combination tested so far.

Token-efficient tooling for driving an **iOS Simulator** from a Claude Code agent.

## Why

An agent asked to "check that the sheet animates in and the email field accepts input" pays
for that check in *observation tokens*. Measured across seven existing tools, the same screen
costs between 78 and 96,873 tokens to observe — a 1,240x spread — while latency varies only
3x. Observation tokens, not latency, are the dominant cost.

MobileController does **not** reimplement device automation. It adopts
[agent-device](https://github.com/callstackincubator/agent-device) (callstack, MIT) as the
automation engine, used strictly as a CLI invoked from Bash — never as an MCP server — and
ships the three things agent-device does not provide:

1. **A Claude Code skill** encoding an observation escalation ladder and the field-tested
   pitfalls (AZERTY text entry, field clearing, session hygiene, the reaper guard).
2. **`simprobe`** — a small Swift CLI that answers "is the screen settled / did it actually
   animate?" with a *number* and zero images returned, using only `xcrun simctl` and
   CoreGraphics. No private APIs, no Python, no codesigning.
3. **A reproducible benchmark harness** that records host loadavg and a control probe next to
   every measurement, so the numbers survive being read on another machine.

## Pinned compatibility

Everything in this repository was verified against exactly one triple:

| Component | Version |
|---|---|
| agent-device | 0.20.10 |
| Xcode | 26.6 |
| iOS Simulator runtime | 26.5 |

When that drifts, re-run the benchmark before trusting any number here.

## Install

Requires macOS 14+ and a Swift 6.0+ toolchain.

```sh
git clone <this-repo> && cd MobileController
swift build -c release
# the binary lands in .build/release/simprobe
```

Add `.build/release` to your `PATH`, or call the binary by its full path.

The automation engine is installed separately and is not vendored here:

```sh
npm i -g agent-device@0.20.10          # or run it ad hoc: npx agent-device@0.20.10 <command>
```

## Install the skill

`skill/` is a Claude Code skill: `SKILL.md` plus three on-demand reference files. Copy the whole
directory — the references are loaded by relative path, so a copy of `SKILL.md` alone is broken.

```sh
# available in every project, for this user
mkdir -p ~/.claude/skills
cp -r skill ~/.claude/skills/mobilecontroller
```

For one project only, put it under that project's `.claude/skills/` instead:

```sh
mkdir -p /path/to/your-app/.claude/skills
cp -r skill /path/to/your-app/.claude/skills/mobilecontroller
```

A symlink works too (`ln -s "$PWD/skill" ~/.claude/skills/mobilecontroller`) and keeps the skill
in step with this checkout. Either way the agent needs `simprobe` and `agent-device` on its
`PATH`; the skill invokes both by bare name.

| File | Loaded | Contents |
|---|---|---|
| `skill/SKILL.md` | always | Escalation ladder, action rule, session hygiene, five hard don'ts |
| `skill/references/agent-device-cheatsheet.md` | on demand | Every verb and flag at 0.20.10, measured costs |
| `skill/references/pitfalls.md` | on demand | Symptom → cause → workaround, incl. the reaper guard |
| `skill/references/simprobe.md` | on demand | The five verbs, exit codes, `--json` shapes |

## Using `simprobe`

Five verbs. Every one has a compact human-readable default, a `--json` form, and an exit code
a shell can branch on. `--udid` accepts a UDID or a device name and defaults to the single
booted simulator, so most invocations need no target at all.

Only `shot --out` and `motion --keep-frames` write anything, and they write wherever you point
them: the path is taken as given, a symlink is followed to its target, and an existing file is
overwritten without a prompt.

```
$ simprobe --help
OVERVIEW: Answer 'is the screen settled?' about an iOS Simulator, in numbers not pixels.

USAGE: simprobe <subcommand>

OPTIONS:
  --version               Show the version.
  -h, --help              Show help information.

SUBCOMMANDS:
  wait-stable             Poll a simulator's screen until it stops changing.
  motion                  Report how much a simulator's screen changed over a window of time.
  shot                    Write one screenshot at 1x logical points and report what it cost.
  devices                 List the simulators on this machine, booted ones first.
  diff                    Compare two image files on the same scale the live verbs use.
```

### `wait-stable [--udid <id>] [--tol 0.5] [--timeout 4s] [--interval 60ms] [--json]`

Captures thumbnails until three consecutive comparisons fall within `--tol`.

```
$ simprobe wait-stable --udid <id>
stable after 1629ms (3 polls, last diff 0.00, tol 0.50)

$ simprobe wait-stable --udid <id> --timeout 1s      # taken during an app launch
not stable after 1017ms (1 poll, last diff 65.51, tol 0.50)
$ echo $?
3

$ simprobe wait-stable --udid <id> --json
{"elapsedMs":1527,"lastDiff":0,"polls":3,"stable":true,"tol":0.5,"udid":"XXXXXXXX-…"}
```

One `simctl` screenshot costs 0.2-1.1 s depending on host load, and a verdict needs four
captures, so a settled screen is reported in 1.5-4 s rather than in the 400 ms the PRD hoped
for. On a loaded machine the default `--timeout 4s` is tight enough that a static screen can be
reported as not stable; raise the timeout rather than lowering `--tol`.

### `motion <ms> [--udid <id>] [--tol 0.5] [--keep-frames <dir>] [--json]`

A diff timeline with **zero image bytes on stdout**. The first capture is a baseline, so the
window starts once there is something to compare against, and every timestamp is measured.

```
$ simprobe motion 2500 --udid <id>          # an app launched ~400 ms in
t=286 0.00, 605 55.66, 838 48.27, 1073 0.01, 1315 0.00, 1553 0.00, 1936 0.00,
   2258 0.27, 2508 0.00  ->  settled@286ms (9 samples, 3.6 fps)

$ simprobe motion 1500 --udid <id> --json   # a screen that never moved
{"fps":2.7,"samples":[{"diff":0,"tMs":279},{"diff":0,"tMs":685},{"diff":0,"tMs":1096},
 {"diff":0,"tMs":1439},{"diff":0,"tMs":1776}],"settledAtMs":279,"tol":0.5}
```

`settledAtMs` is the **first** sample within tolerance, so on a screen that was already quiet
when the window opened it reports that first quiet sample rather than the end of the animation
that followed. Read the timeline, not just the settle point.

`--keep-frames <dir>` is the only path that writes images: one PNG per sample, up to 10 000 of
them. Past that the frames stop and the run says so (`(frames capped at 10000)`, or
`"framesCapped": true` under `--json`); the timeline itself always runs to the end of the window.

### `shot [--udid <id>] [--out shot.jpg] [--width <px>] [--quality 70] [--scale <n>] [--json]`

One screenshot at 1x logical points, so a coordinate read off the image maps 1:1 onto the
accessibility frame. The framebuffer scale is read from `simctl io <udid> enumerate`
(`Preferred UI Scale` on the integrated screen), not hardcoded; `--scale` overrides it.

```
$ simprobe shot --udid <id> --out /tmp/settings.jpg
/tmp/settings.jpg  402x874 @1x  jpeg q70  47.4 KB  ~468 vision tokens  (source 1206x2622, 3.0x)
```

### `devices [--booted] [--json]`

The pinning `agent-device` lacks: its `--device` matches names only, and duplicate names are
common. Feed the UDID column to `agent-device --udid`.

```
$ simprobe devices
BOOTED  iPhone 17          iOS 26.5   XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
        iPhone 17 Pro      iOS 26.5   XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
        iPad Pro 13-inch   iOS 26.4   XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
3 devices, 1 booted
```

### `diff <before> <after> [--tol 0.5] [--json]`

```
$ simprobe diff /tmp/home.jpg /tmp/home.jpg
diff 0.00  (40x87 gray, tol 0.50)  ->  same

$ simprobe diff /tmp/settings.jpg /tmp/home.jpg
diff 64.36  (40x87 gray, tol 0.50)  ->  different
$ echo $?
4
```

### Exit codes

| Code | Meaning |
|---:|---|
| 0 | Success, and for `diff` "same within tolerance" |
| 1 | Usage or invalid arguments |
| 2 | Environment: `simctl` missing or failing, no booted simulator, ambiguous `--udid` |
| 3 | `wait-stable` timed out before the screen settled |
| 4 | `diff` exceeded tolerance |
| 5 | Capture or decode failure |

Under `--json`, errors are printed on **stdout** as `{"error":{"code":2,"kind":…,"message":…}}`
so a caller parsing stdout never has to scrape stderr. Without `--json` the message goes to
stderr and stdout stays empty.

## Measured on an 8-core Apple Silicon Mac, Xcode 26.6, iPhone 17 / iOS 26.5

Regenerate both tables with one command each:

```sh
bench/run.sh --target settings --repeat 3
bench/run.sh --target demoapp  --repeat 3
```

> **Read ratios, not absolutes.** wall_ms inflates 2-10x when loadavg_1m rises
> above roughly 2x the core count of the machine that produced the row, so
> compare control_probe_ms across rows first: if it moved with wall_ms the host
> was loaded, and only a step whose wall_ms moved while control_probe_ms held
> steady is a real regression. est_tokens is stdout_bytes/4 - an estimate of
> observation cost, not a token count.

Host `loadavg_1m` sat between 5.6 and 6.7 on 8 cores throughout - loaded, but
well below the ~2x-cores line where wall clock starts to lie. `control_probe_ms`
held between 160 and 340 ms across every row of both runs, which is what says so
independently: it reaches the same simulator without going through agent-device.
Both tables are trimmed to the one-off rows plus one representative repeat of
three; the full CSV is in `bench/out/<timestamp>/results.csv`.

`ad` and `sp` are the wrappers in `bench/lib/flow.sh` - they add `--udid` and
`--session` to every call, which is why no UDID appears in the `cmd` column.

### `--target settings` - Apple Settings, the app nobody controls

| flow | step | cmd | wall_ms | stdout_bytes | est_tokens | loadavg_1m | control_probe_ms | exit_code |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| settings-observe-act | 0-open_cold | ad open com.apple.Preferences | 1863 | 87 | 21 | 6.50 | 197 | 0 |
| settings-observe-act | 0-close_cold | ad close | 159 | 14 | 3 | 6.50 | 270 | 0 |
| settings-observe-act | r2-open_warm | ad open com.apple.Preferences | 1333 | 87 | 21 | 6.61 | 195 | 0 |
| settings-observe-act | r2-digest_snapshot | ad --level digest --json snapshot -i | 323 | 447 | 111 | 6.64 | 265 | 0 |
| settings-observe-act | r2-interactive_snapshot | ad snapshot -i | 301 | 851 | 212 | 6.64 | 192 | 0 |
| settings-observe-act | r2-full_snapshot | ad snapshot | 286 | 3152 | 788 | 6.64 | 187 | 0 |
| settings-observe-act | r2-press_row | ad press text=Général | 878 | 33 | 8 | 6.64 | 176 | 0 |
| settings-observe-act | r2-wait_stable | sp wait-stable --timeout 6s | 1259 | 56 | 14 | 6.64 | 337 | 0 |
| settings-observe-act | r2-press_row_settle | ad press text=Général --settle | 3283 | 1491 | 372 | 6.19 | 210 | 0 |
| settings-observe-act | r2-simprobe_shot | sp shot --out bench/out/20260826T204437/settings-shot-r2.jpg | 532 | 164 | 41 | 6.01 | 208 | 0 |
| settings-observe-act | r2-agent_screenshot | ad screenshot --out bench/out/20260826T204437/settings-screenshot-r2.png | 485 | 106 | 26 | 6.01 | 191 | 0 |
| settings-observe-act | r2-close | ad close | 114 | 14 | 3 | 6.01 | 180 | 0 |

The ladder, read across `stdout_bytes`: **447 B digest, 851 B interactive,
3152 B full** for one and the same screen - a 7x spread for the same question.
Acting is nearly free at 33 B; `press --settle` costs **1491 B and 3283 ms**
against **33 B and 878 ms** bare, because the settled diff comes back with it.
Use it when the diff *is* the verification, not when the next step re-observes.

The two screenshots are the same picture: the one-line paths on stdout are 164 B
and 106 B, but the files are 47 KB (`simprobe shot`, 402x874 at 1x, ~468 vision
tokens) and 92 KB. What a model pays for is the image, not the line.

`0-open_cold` is the first open of the run, not the first open the machine ever
did: on a device that has never hosted the runner it also builds and installs
the XCUITest runner, tens of seconds that this row does not show. The Settings
row is addressed by label and Settings is localised, hence `text=Général` here -
set `BENCH_SETTINGS_ROW` in `bench/local.env` to match your device's language.

### `--target demoapp` - the same ladder against a known 300 ms transition

| flow | step | cmd | wall_ms | stdout_bytes | est_tokens | loadavg_1m | control_probe_ms | exit_code |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| demoapp-observe-act | 0-open | ad open dev.mobilecontroller.demoapp | 2287 | 94 | 23 | 6.49 | 253 | 0 |
| demoapp-observe-act | r2-tab_list | ad press id=tabBar.list | 708 | 33 | 8 | 6.01 | 193 | 0 |
| demoapp-observe-act | r2-wait_stable_list | sp wait-stable --timeout 6s | 1231 | 56 | 14 | 6.01 | 192 | 0 |
| demoapp-observe-act | r2-interactive_snapshot | ad snapshot -i | 311 | 1055 | 263 | 6.01 | 194 | 0 |
| demoapp-observe-act | r2-tab_form | ad press id=tabBar.form | 843 | 33 | 8 | 6.01 | 174 | 0 |
| demoapp-observe-act | r2-wait_stable_form | sp wait-stable --timeout 6s | 1308 | 56 | 14 | 6.01 | 179 | 0 |
| demoapp-observe-act | r2-fill_textfield | ad fill id=form.textField example.com | 2449 | 16 | 4 | 6.17 | 186 | 0 |
| demoapp-observe-act | r2-get_echo | ad get attrs id=form.echoLabel | 634 | 266 | 66 | 6.17 | 177 | 0 |
| demoapp-observe-act | r2-is_echo_text | ad is text id=form.echoLabel example.com | 633 | 16 | 4 | 6.17 | 171 | 0 |
| demoapp-observe-act | r2-press_clear | ad press id=form.clearButton | 864 | 38 | 9 | 6.00 | 178 | 0 |
| demoapp-observe-act | r2-wait_stable_clear | sp wait-stable --timeout 6s | 1239 | 56 | 14 | 6.00 | 186 | 0 |
| demoapp-observe-act | r2-get_echo_cleared | ad get attrs id=form.echoLabel | 658 | 262 | 65 | 6.00 | 160 | 0 |
| demoapp-observe-act | r2-dismiss_keyboard | ad keyboard return | 1465 | 23 | 5 | 6.00 | 183 | 0 |
| demoapp-observe-act | r2-tab_home | ad press id=tabBar.home | 766 | 33 | 8 | 5.83 | 170 | 0 |
| demoapp-observe-act | r2-wait_stable_home | sp wait-stable --timeout 6s | 1218 | 56 | 14 | 5.83 | 261 | 0 |
| demoapp-observe-act | r2-press_animate_motion | bench_flow_press_then_motion id=home.animateButton 1500 | 1930 | 116 | 29 | 5.83 | 174 | 0 |

`r2-press_animate_motion` is the row the DemoApp exists for. The tap runs in the
background inside that step so the 300 ms transition happens *inside* the
capture window; a foreground `press` returns only after the runner acknowledges
it, ~1.5 s later, by which time there is nothing left to measure. The three
timelines, verbatim:

```
r1: t=219 0.16, 453 20.04, 687 15.26, 917 0.04, 1151 0.00, 1377 0.00, 1597 0.00  ->  settled@917ms (7 samples, 4.4 fps)
r2: t=202 0.16, 431 22.86, 669 12.06, 904 0.09, 1140 0.00, 1366 0.00, 1583 0.00  ->  settled@904ms (7 samples, 4.3 fps)
r3: t=214 0.16, 451 14.09, 686 21.02, 918 0.16, 1145 0.00, 1379 0.00, 1610 0.00  ->  settled@918ms (7 samples, 4.3 fps)
```

Two consecutive samples at ~14-23 against a floor of 0.00-0.16, then quiet: a
300 ms animation straddling two ~230 ms capture windows, three times out of
three. Note what `settled@` says - 904-918 ms - and what it means: the first
*quiet* sample, one cadence after the motion ended, not the end of the
animation. Read the whole timeline; `settled@` alone would be off by 300 ms
here, and on a screen that was already still it is simply the first sample.

`ad get attrs` rather than `ad get text`: on a label carrying both, `get text`
returns the accessibility label (`Echo`) while the echoed value lives in
`value`. `r2-dismiss_keyboard` is there because after a `fill` the keyboard
covers the tab bar, and a press on a tab then reports `Tapped id=tabBar.home`
and changes nothing - `agent-device keyboard dismiss` is unsupported on iOS, so
the return key is the way out.

## Documentation

The design is written down before the code, in three documents:

- [PRD](docs/plans/01-prd.md) — problem, goals, measured baseline, acceptance targets.
- [Architecture](docs/plans/02-architecture.md) — repo layout, module split, CLI surface,
  exit codes.
- [Task list](docs/plans/03-task-list.md) — phased tasks with their TDD red steps.

## Credits

- [agent-device](https://github.com/callstackincubator/agent-device) by callstack — MIT.
  MobileController is a complement to it, not a fork of it.

## Licence

MIT — see [LICENSE](LICENSE).
