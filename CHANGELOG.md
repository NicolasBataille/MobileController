# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow SemVer.

## [Unreleased]

### Added
- `simprobe frames`: the on-screen accessibility elements with their **1x coordinates** — the
  thing an agent-device snapshot never reports. Banded by vertical position, one line per
  element, `#accessibilityIdentifier` or `@index` as the ref, labels cut at 40 characters,
  `--interactive`, `--point x,y` and `--json`. Reads frames through `idb`
  (`brew install facebook/fb/idb-companion && pip3 install fb-idb`), retrying once through
  `idb connect` because the first call after a simulator boots fails by design.
- Two exit-2 error kinds: `dependencyMissing` (carrying the install line) and `idbFailed`.
- `Formula/simprobe.rb`: a Homebrew formula living in this repository rather than in a separate
  tap — `brew tap NicolasBataille/MobileController <url>`, `brew trust
  nicolasbataille/mobilecontroller`, `brew install simprobe`. Builds from the release tarball
  with `swift build -c release --disable-sandbox`. Verified end to end on Homebrew 6.0.19.
- `scripts/bump-formula.sh <tag>`: rewrites the formula's url and sha256 from the real tarball,
  so a release cannot silently ship the previous binary.

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
