# MobileController — Architecture (v1)

Companion to `01-prd.md`. Decisions are stated, then justified in one line.

## 1. Repo layout

```
MobileController/
├── Package.swift                 # SwiftPM manifest AT ROOT
├── LICENSE                       # MIT
├── README.md
├── Sources/
│   ├── SimProbeCore/             # pure library, no process spawning, no simulator
│   └── simprobe/                 # executable: ArgumentParser + IO adapters
├── Tests/
│   ├── SimProbeCoreTests/        # unit, hermetic, runs anywhere
│   └── SimProbeCLITests/         # CLI wiring + golden output; sim tests skipped by default
├── skill/
│   ├── SKILL.md                  # ~120 lines, the only always-resident context
│   └── references/
│       ├── agent-device-cheatsheet.md
│       ├── pitfalls.md           # AZERTY, field clear, sessions, REAPER GUARD
│       └── simprobe.md
├── bench/
│   ├── run.sh                    # entry point
│   ├── flows/                    # one file per scenario
│   ├── lib/                      # timing, byte counting, loadavg, control probe
│   └── out/                      # git-ignored artifacts
├── DemoApp/
│   ├── project.yml               # XcodeGen spec (no .xcodeproj committed)
│   └── Sources/
├── docs/plans/                   # these documents
└── .github/workflows/ci.yml
```

**`Package.swift` at the repo root, not in `Probe/`.** The install story is
`git clone && swift build -c release`; a nested package makes that two steps and breaks
`swift run` from the clone root. The existing `.gitignore` already lists `.build/` and
`.swiftpm/` at root, which assumes this. Cost: the repo root mixes Swift and non-Swift
directories — acceptable, and `swift build` ignores `skill/`, `bench/`, `DemoApp/`.

## 2. Swift module split

**`SimProbeCore`** — a library of pure, synchronous functions. No `Process`, no `FileManager`
writes, no clock reads. Everything it needs arrives as a parameter.

- `Thumbnail`: `downscale(_ image: CGImage, to: Size) -> GrayFrame` — 40x87 grayscale by
  default; `GrayFrame` is `[UInt8]` + dimensions, `Equatable`, immutable.
- `FrameDiff`: `meanAbsoluteDifference(_ a: GrayFrame, _ b: GrayFrame) throws -> Double`.
  Throws `.sizeMismatch` rather than returning a meaningless number.
- `StabilityEvaluator`: `struct` folding a sequence of diffs into
  `StabilityVerdict { .settled(afterMs: Int, polls: Int) | .timedOut(lastDiff: Double, polls: Int) }`.
  Pure state machine; the poll loop lives in the executable.
- `MotionTimeline`: `[TimelineSample]` → formatted default and JSON forms.
- `ScreenshotBudget`: `plan(sourcePixelSize:pointSize:targetWidth:) -> EncodePlan`, encoding
  the 3x-framebuffer / 1x-points relationship and the vision-token estimate.

**`simprobe`** — ArgumentParser commands, one file per verb, plus the IO adapters.

IO sits behind two small protocols so the core is testable with no simulator and no disk:

```swift
protocol ScreenCapturing {                       // real impl: xcrun simctl io <udid> screenshot <tmpfile>
    func capture(udid: String) throws -> CGImage
}
protocol DeviceListing {                          // real impl: xcrun simctl list devices --json
    func devices() throws -> [SimulatorDevice]
}
protocol Clock { var nowMs: Int { get }; func sleep(ms: Int) }
```

Tests inject a `ScriptedCapture` returning a fixed frame sequence and a `VirtualClock`, so
`wait-stable`'s "settled after 180ms (3 polls)" is asserted deterministically with zero
simulator involvement. Every file stays under 400 lines; every function under 50.

**Dependencies:** `swift-argument-parser` only. CoreGraphics/ImageIO are system frameworks.
No private frameworks, no `dlopen` — CI greps for `dlopen|AXPTranslator|SimulatorKit` and fails.

**Immutability:** all model types are `struct` with `let`; transformations return new values.
The only mutable state is the poll loop's local accumulator inside a single function.

## 3. Capture constraints baked into the design

- `xcrun simctl io <udid> screenshot -` does **not** stream to stdout; it writes a file
  literally named `-`. Always capture to a temp file in `NSTemporaryDirectory()`, read it,
  delete it in a `defer`.
- Capture floor is ~200 ms per call → burst ceiling ~3.5 fps. `--interval 60ms` therefore
  means "no artificial delay"; the real cadence is capture-bound. `motion` reports actual
  sample timestamps, never assumed ones.
- The framebuffer is exactly 3x logical points on current iPhone hardware, but this is
  **derived from the captured image**, not hardcoded: `shot` reads the pixel size and divides
  by the reported point size.

## 4. CLI surface and output samples

Every verb: compact human-readable default, `--json` for machine use, `--udid` optional
(resolves to the single booted simulator when omitted, errors when ambiguous).

### `simprobe wait-stable [--tol 0.5] [--timeout 4s] [--interval 60ms] [--udid <id>]`
```
$ simprobe wait-stable
stable after 180ms (3 polls, last diff 0.01, tol 0.50)

$ simprobe wait-stable --timeout 1s          # still animating
not stable after 1004ms (5 polls, last diff 3.20, tol 0.50)
$ echo $?
3

$ simprobe wait-stable --json
{"stable":true,"elapsedMs":180,"polls":3,"lastDiff":0.011,"tol":0.5,"udid":"…"}
```

### `simprobe motion <ms> [--tol 0.5] [--keep-frames <dir>] [--udid <id>]`
```
$ simprobe motion 600
t=0 11.00, 210 3.20, 415 0.40, 620 0.01  ->  settled@415ms (4 samples, 4.9 fps)

$ simprobe motion 600 --json
{"settledAtMs":415,"hadMotion":true,"samples":[{"tMs":0,"diff":11.0},{"tMs":210,"diff":3.2},
 {"tMs":415,"diff":0.4},{"tMs":620,"diff":0.01}],"tol":0.5,"fps":4.9}
```
Zero image bytes on stdout in either form. `--keep-frames <dir>` writes PNGs for a human.

### `simprobe shot [--out <path>] [--width 420] [--quality 70] [--udid <id>]`
```
$ simprobe shot --out /tmp/s.jpg
/tmp/s.jpg  402x874 @1x  jpeg q70  46.1 KB  ~468 vision tokens  (source 1206x2622, 3.0x)
```
Default `--width` is the device's logical point width (1x), not a constant — 1x is the whole
point: a coordinate read off the image maps 1:1 onto the accessibility frame.

### `simprobe devices [--json] [--booted]`
```
$ simprobe devices
BOOTED  iPhone 17          iOS 26.5   XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
        iPhone 17 Pro      iOS 26.5   XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
        iPad Pro 13-inch   iOS 26.5   XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
3 devices, 1 booted
```
This is the pinning agent-device lacks: `--device` matches names only, and duplicate names are
common. Feed the UDID to `agent-device --udid`.

### `simprobe diff <a.png> <b.png> [--tol 0.5] [--json]`
```
$ simprobe diff base.png now.png
diff 0.03  (40x87 gray, tol 0.50)  ->  same
$ echo $?
0
```
Exit 4 when the images differ beyond `--tol`, so shell `&&` chains read naturally.

## 5. Error handling and exit codes

Every error is an explicit `ProbeError` case with a one-line message on **stderr**; stdout
carries only the result. No error is swallowed; no partial result is printed as if complete.

| Code | Meaning |
|---:|---|
| 0 | Success (and, for `diff`, "same within tolerance") |
| 1 | Usage / invalid arguments |
| 2 | Environment: `xcrun` missing, `simctl` failed, no booted simulator, ambiguous UDID |
| 3 | `wait-stable` timed out before the screen settled |
| 4 | `diff` exceeded tolerance |
| 5 | Capture or decode failure (unreadable PNG, size mismatch between frames) |

`--json` errors still print JSON on stdout (`{"error":{"code":2,"kind":"noBootedDevice",…}}`)
so an agent parsing output never has to fall back to scraping stderr.

## 6. DemoApp — yes, with Settings as the default bench target

**Ship `DemoApp/`, but make Apple Settings (`com.apple.Preferences`) the zero-setup default
for `bench/run.sh`.** Settings needs no build and works on any machine, but its content
changes across iOS versions and it offers no controlled animation. DemoApp gives the bench a
deterministic target: a tab bar (a transition to time), a list (a dense tree to snapshot), a
text field (the `fill`/AZERTY/field-clear path), and one explicit 300 ms animated transition
behind a button (a known ground truth for `wait-stable` and `motion`).

**`.xcodeproj` conflict, resolved:** `.gitignore` ignores `*.xcodeproj`, and committing a
generated project file to a public repo is churn. `DemoApp/` therefore commits **`project.yml`
(XcodeGen) + `Sources/`**, and `bench/lib/demoapp.sh` runs `xcodegen generate` before
`xcodebuild build-for-testing`. XcodeGen is a bench-only, opt-in dependency: nothing in
`swift build`, `swift test`, or the skill needs it, and `run.sh` against Settings never
invokes it.

`.gitignore` also ignores `*.png`/`*.jpg`, so the bench must **generate** every image it needs
into git-ignored `bench/out/` — no committed screenshot baselines in v1.

## 7. Bench design

`bench/run.sh [--target settings|demoapp] [--flow <name>] [--repeat 3]`. Each flow is a shell
file declaring numbered steps. For every step the harness records:

`flow, step, cmd, wall_ms, stdout_bytes, est_tokens, loadavg_1m, control_probe_ms, exit_code`

- `est_tokens` = `stdout_bytes / 4`, stated as an estimate in the header, not as truth.
- `control_probe_ms` = one `xcrun simctl io <udid> screenshot` immediately before the step.
  Host load swung 5→450 during the bake-off and inflated wall-clock 2–10x; without this column
  the CSV is unusable across machines. `agent-device --cost` (`cost.wallClockMs`) is recorded
  alongside where available, as the engine's own view of the same step.
- Output: `bench/out/<timestamp>/results.csv` plus a rendered markdown table.
- **Teardown is `agent-device close` then `agent-device daemon stop --clean` (the sanctioned
  reclaim of retained runner processes and leases). No `pkill`, ever** — reaping the
  in-simulator runner poisons accessibility device-wide until reboot. (The in-sim runner also
  idle-stops on its own after ~5 min by default, so surviving processes are time-bounded
  regardless.) `run.sh` contains a comment saying so at the teardown site, and CI greps the
  repo for `pkill`.
- User-specific targets (a private app's bundle id, a device name) come from a git-ignored
  `bench/local.env` or `SIMPROBE_*` environment variables. Nothing user-specific is committed.

## 8. Skill layout

`skill/SKILL.md` is the only always-resident cost, so it is capped at ~120 lines: the
escalation ladder, the settle rule, the five hard don'ts (HID `type`, select-all on non-QWERTY,
`pkill`, implicit sessions, `--device` with a UDID), and pointers into `references/`. The
reference files are loaded on demand and may be longer. The header pins
`agent-device 0.20.10 / Xcode 26.6 / iOS 26.5` and says what to re-verify when that drifts.

Install is a documented `cp -r skill ~/.claude/skills/mobilecontroller` (or a symlink); v1
ships no installer.

## 9. Install and CI

- **v1:** `git clone && swift build -c release` → `.build/release/simprobe`. README documents
  adding it to `PATH`. agent-device is the user's own `npm i -g agent-device@0.20.10`.
- **Later:** a Homebrew tap, once the CLI surface has stopped moving.
- **CI** (`.github/workflows/ci.yml`, `macos-15` runner): `swift build`, `swift test
  --enable-code-coverage`, a coverage floor check on `SimProbeCore`, `swift format lint`, and
  a hygiene job grepping for `dlopen|AXPTranslator|SimulatorKit`, `pkill`, `/Users/`, and
  UDID-shaped strings. Simulator-dependent tests are tagged and **skipped** unless
  `SIMPROBE_LIVE=1` is set, so CI is green without a booted device (PRD A5).
