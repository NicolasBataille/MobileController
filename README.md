# MobileController

**Status: pre-alpha.** Nothing here is stable yet. The plans are written, and the
`simprobe` CLI verbs have landed; the skill and the benchmark harness have not.

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

The automation engine is installed separately and is not vendored here:

```sh
npm i -g agent-device@0.20.10
```

## Using `simprobe`

Five verbs. Every one has a compact human-readable default, a `--json` form, and an exit code
a shell can branch on. `--udid` accepts a UDID or a device name and defaults to the single
booted simulator, so most invocations need no target at all.

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

`--keep-frames <dir>` is the only path that writes images: one PNG per sample.

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
