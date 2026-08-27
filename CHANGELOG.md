# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow SemVer.

## [Unreleased]

### Added
- **The warm action daemon.** `simprobe-daemon` holds one gRPC connection to `idb_companion` open,
  and `simprobe` talks to it over a newline-delimited JSON protocol on a per-UDID unix socket at
  `$TMPDIR/simprobe/<udid>.sock`. Measured against the same simulator: a tap costs **16 ms** of
  wall clock instead of `agent-device press`'s ~1.0-1.5 s, a tree **82 ms** instead of
  `snapshot -i`'s ~0.3-0.5 s, and a 20-iteration tap+tree loop **2.05 s** instead of ~26-40 s. The
  spike's mixed-loop measurement was **2.7x** end to end with an XCUITest session live on the same
  device. Design and caveats: `docs/plans/05-warm-daemon.md`.
- `simprobe daemon start|stop|status`. `start` spawns the daemon detached, waits for it to answer,
  then smoke-tests **both** halves — a tree with at least one element *and* a `simctl` screenshot,
  because idb's own screenshot breaks once its companion outlives a simulator reboot. `stop` is the
  only thing here that signals a process, and only one its own daemon wrote down whose executable
  still matches; a recycled pid from a stale file is discarded, never killed. `status` exits 0
  either way: absence is a result.
- `simprobe tap <#id | @index | x,y> [--wait-stable]`, which resolves a ref against a fresh tree
  with the parser `frames` already uses and taps the centre of the element's frame, and
  `simprobe tree [--interactive] [--json]`, which is `frames`' output from the warm path.
- Exit-2 error kind `daemonUnavailable`, carrying the exact `simprobe daemon start` line. `tap` and
  `tree` deliberately do **not** autostart a daemon: hiding a ~1.6 s cold start inside a tap makes
  one iteration of a loop mysteriously slow.
- `scripts/regen-idb-stubs.sh`, which regenerates the vendored protobuf/gRPC stubs under
  `Sources/SimProbeDaemon/Generated/` from **the installed idb client's own descriptor** rather
  than from upstream `idb.proto` — upstream has grown fields the released companion rejects, so
  generating from the descriptor is wire-compatible by construction.

### Changed
- Two executable products instead of one. `simprobe` keeps its single dependency and its ~1-minute
  clean build (58 s measured, 2.7 MB); gRPC's 22 transitive packages live in `simprobe-daemon`
  alone (38.5 MB), and `swift build --product simprobe` never compiles any of them.
- `Formula/simprobe.rb` installs both binaries and asserts both in `test do`. The change takes
  effect at the next `scripts/bump-formula.sh` tag; the pinned v0.2.0 tarball predates it.
- `skill/SKILL.md` gains a "fast action path" paragraph and loses redundancy elsewhere to stay
  within its line budget.

## [0.2.0] — 2026-08-27

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

[0.2.0]: https://github.com/NicolasBataille/MobileController/releases/tag/v0.2.0
[0.1.0]: https://github.com/NicolasBataille/MobileController/releases/tag/v0.1.0
