# bench/

A reproducible benchmark for the observation ladder: how many bytes (and so how
many estimated tokens) each way of looking at a screen costs, and how long it
takes. Emits a CSV plus a markdown table under the git-ignored `bench/out/`.

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
/bin/bash bench/lib/test.sh
```

Plain bash, no `bats`. Exits non-zero on failure. `xcrun` is stubbed through a
PATH shim, so the suite touches no simulator and boots nothing. Run it with
`/bin/bash` specifically: the library targets macOS's system bash 3.2 (no
associative arrays, no `mapfile`, no `date +%s%N`), and a newer bash on `$PATH`
would hide a 3.2 incompatibility.

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
