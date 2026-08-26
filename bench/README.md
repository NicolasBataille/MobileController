# bench/

A reproducible benchmark for the observation ladder: how many bytes (and so how
many estimated tokens) each way of looking at a screen costs, and how long it
takes. Emits a CSV plus a markdown table under the git-ignored `bench/out/`.

## Running it

```sh
swift build -c release                    # produces .build/release/simprobe
npm i -g agent-device@0.20.10             # the pinned engine
cp bench/local.env.example bench/local.env && $EDITOR bench/local.env

bench/run.sh --target settings            # Apple Settings: no app to build
bench/run.sh --target demoapp --repeat 5  # builds + installs DemoApp first
```

`run.sh` prints the path of the rendered markdown table and nothing else, so it
composes: `open "$(bench/run.sh --target settings)"`.

| Flag | Meaning |
| --- | --- |
| `--target settings` | `bench/flows/settings-observe-act.sh`. Needs only a booted simulator. |
| `--target demoapp` | XcodeGen + `xcodebuild` into a scratch `derivedData` under the run's own output directory, `simctl install`, then `bench/flows/demoapp-observe-act.sh`. |
| `--repeat N` | Repeats of the warm part of the flow. Default 3. |
| `--out DIR` | Output directory. Default `bench/out/<timestamp>`. |

## The two flows

**`settings-observe-act.sh`** walks the ladder against a screen nobody controls.
One `open_cold` and one `close_cold`, then per repeat: `open_warm`, the same
screen read three ways (`--level digest --json snapshot -i`, `snapshot -i`, full
`snapshot`), a bare `press` on a row followed by `simprobe wait-stable`, the same
`press --settle` for the side-by-side, then `simprobe shot` against
`agent-device screenshot`, and a `close`.

The row is addressed by label, and Settings is localised, so a device that is
not in English needs `BENCH_SETTINGS_ROW` set in `bench/local.env`. It is the
only part of the flow that is not device-independent.

**`demoapp-observe-act.sh`** walks the same ladder where the ground truth is
known. Tabs by identifier, `fill` / read back / `press` the clear button / read
back `(empty)`, and then the measurement the whole DemoApp exists for: a tap on
`home.animateButton`, which drives exactly one 300 ms `easeInOut` transition,
with `simprobe motion 1500` running across it. A `simctl` capture costs ~200 ms,
so a correct timeline is one or two non-zero samples and then quiet:

```
t=219 0.16, 453 20.04, 687 15.26, 917 0.04, 1151 0.00, 1377 0.00, 1597 0.00
```

The tap is issued in the background inside that step on purpose. A foreground
`press` returns only once the in-simulator runner has acknowledged it, one to
one and a half seconds later, by which point a 300 ms transition is long over:
measuring the two in series reports a flat timeline for an animation that really
happened. Read the **whole** timeline, never `settled@` alone - it is the first
quiet sample, which on an already-quiet screen is the first sample of all.

## Dry run

`BENCH_DRY_RUN=1` records every step's tag and command line without executing
it and without touching a simulator, so the flow scripts - their loops, their
step tags, their argument construction - are exercised on a machine with no
device, no agent-device and no Xcode. Timing columns are `0` in that mode: they
are deliberately not fabricated.

```sh
BENCH_DRY_RUN=1 bench/run.sh --target demoapp --repeat 1
```

`bench/lib/` is the measurement library. Flows and `run.sh` arrive with T4.2.

## Columns

Fixed header, documented in `docs/plans/02-architecture.md` (Bench design):

```
flow,step,cmd,wall_ms,stdout_bytes,est_tokens,loadavg_1m,control_probe_ms,exit_code
```

| Column | Meaning |
| --- | --- |
| `flow` | The flow file that produced the row (`$BENCH_FLOW`). |
| `step` | The step tag within the flow, e.g. `1-open`, `2-digest`. |
| `cmd` | The command line that was measured. Quoted if it contains a comma. |
| `wall_ms` | Wall-clock milliseconds for the command alone. |
| `stdout_bytes` | Bytes the command wrote to stdout - the observation cost. |
| `est_tokens` | `stdout_bytes / 4`, integer-truncated. An **estimate**, not a token count. |
| `loadavg_1m` | Host 1-minute load average when the step ran. Always dot-decimal. |
| `control_probe_ms` | One `xcrun simctl io <udid> screenshot`, timed immediately before the step. |
| `exit_code` | The command's exit status. A failed step is data, not a crash. |

## The caveat

**Read ratios, not absolutes.** `wall_ms` inflates 2-10x when `loadavg_1m` rises
above roughly 2x the core count of the machine that produced the row. During the
bake-off host load swung 5 to 450 and moved every wall-clock number with it; a
benchmark that hides that is worse than none.

`control_probe_ms` is the independent yardstick. It reaches the same simulator
over a path that does not involve agent-device, so:

- `control_probe_ms` moved with `wall_ms` -> the host was loaded, not a regression.
- `wall_ms` moved while `control_probe_ms` held steady -> a real regression.

`est_tokens` is a bytes/4 heuristic for comparing observation forms against each
other. It is not what a model would actually be billed.

## Running the tests

```sh
/bin/bash bench/lib/test.sh      # the measurement library
/bin/bash bench/flows/test.sh    # the flows and run.sh, under BENCH_DRY_RUN=1
```

Plain bash, no `bats`. Exits non-zero on failure. Neither suite touches a
simulator: the library tests stub `xcrun` through a PATH shim, and the flow
tests run everything as a dry run. Both are wired into CI. Run them with
`/bin/bash` specifically: the code targets macOS's system bash 3.2 (no
associative arrays, no `mapfile`, no `date +%s%N`), and a newer bash on `$PATH`
would hide a 3.2 incompatibility.

`bench/flows/test.sh` also asserts that no UDID-shaped string reaches the CSV or
the rendered markdown. That is not paranoia about the file: the `cmd` column is
published, first into `results.md` and then into the repo's README. Flows
therefore address the device through the `ad` / `sp` wrappers in
`bench/lib/flow.sh` rather than expanding `$BENCH_UDID` at the call site.

## Teardown - never `pkill`

End a run with `bench_teardown_agent_device <session>`, which runs
`agent-device close --session <s>` then `agent-device daemon stop --clean`.

Never `pkill` the in-simulator XCUITest runner. Reaping it poisons accessibility
device-wide until the simulator is rebooted - every later query returns empty or
stale trees, on every session, for every tool. If a process somehow survives,
reboot the simulator. (It also idle-stops on its own after ~5 minutes.)

## Configuration

Machine-specific values - a UDID, a private bundle id - come from the git-ignored
`bench/local.env`. Copy `bench/local.env.example` and fill it in. Nothing
user-specific is committed, and `bench/out/` is ignored too: the bench generates
every image it needs rather than committing baselines.

This file is sourced by bash (`bench/run.sh`): anything in it runs with your
privileges. Keep it to KEY=value lines.
