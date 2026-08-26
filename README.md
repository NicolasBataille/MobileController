# MobileController

**Status: pre-alpha.** Nothing here is stable yet. The plans are written, Phase 0/1 of the
implementation has landed, the CLI verbs have not.

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
