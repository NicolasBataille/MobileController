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

### Changed
- `bench/flows/demoapp-observe-act.sh`: the step that reads the echo label back is now
  `get_echo_value` (`agent-device get attrs id=form.echoLabel`, matching the `value` field
  exactly) instead of `is_echo_text` (`agent-device is text …`), which compared against the
  accessibility **label** (`Echo`) and so exited 1 by construction.
- README: both measured tables regenerated on iPhone 17 Pro / iOS 26.5 with agent-device
  `0.20.11-mc.1`, stated in the section heading. The digest rung measured **1515 B** against
  851 B for `snapshot -i` on the same screen — larger than rung 2, where 0.20.10 read 447 B —
  so the ladder prose and the skill's rung-1 cost now carry that caveat.

### Docs
- docs: warm-daemon spike results
- README ▸ *Optional: patched agent-device build*: how to build and install `0.20.11-mc.1` from
  `NicolasBataille/agent-device` branch `mobilecontroller/patched`, and which of the five known
  upstream limitations it fixes. 0.20.10 remains the documented baseline the skill is pinned to.
- `skill/references/pitfalls.md`: entries 2, 3, 4, 6 and 7 gained a *Fixed in the patched build /
  upstream PR #N* line rather than being deleted — on the pinned 0.20.10 they are all still live.
  Entry 3's claim that `session list` "shows what exists" is corrected: it filters by the caller's
  scope on both builds.
- `skill/references/pitfalls.md`: two new entries — §14 `session list` hides a session opened with
  an explicit `--session`, and §15 `is text` / `get text` read the accessibility label, not the
  value (use `get attrs` and match `value`). Both verified live on `0.20.11-mc.1`.

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
