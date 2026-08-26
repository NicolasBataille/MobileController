# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow SemVer.

## [0.1.0] — 2026-08-26

First public alpha, measured on Xcode 26.6 / iOS 26.5 with agent-device 0.20.10.

### Added
- `simprobe` CLI (Swift, no private APIs): `wait-stable`, `motion`, `shot`, `devices`, `diff`,
  with `--json` output and documented exit codes.
- Claude Code skill (`skill/`): agent-device conventions, observation escalation ladder,
  session hygiene, pitfalls and a simprobe reference.
- Benchmark harness (`bench/`) recording wall time, bytes, estimated tokens, host load and a
  control probe per step; Settings and DemoApp flows.
- `DemoApp/`: a public SwiftUI benchmark target (tabs, list, form, 300 ms transition).
- CI with a public-repo hygiene gate and an 80 % coverage floor.

### Known limitations
- Pinned to agent-device 0.20.10; see README "Known upstream limitations".
- `wait-stable` needs ≥ 3 captures (~1.5–4 s) with default `--quiet-polls 3`.

[0.1.0]: https://github.com/NicolasBataille/MobileController/releases/tag/v0.1.0
