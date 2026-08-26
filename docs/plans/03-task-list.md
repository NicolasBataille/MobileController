# MobileController — Task List (v1)

Each task is sized for one subagent (≤ ~2 h) and names its dependencies. TDD is mandatory:
the RED step lists the literal test names to write **first**, which must fail before any
implementation exists. "DoD" = definition of done for that task alone.

Conventions: conventional commits; one task = one branch = one PR; files < 800 lines,
functions < 50; no `pkill` anywhere; no personal path, UDID, or private bundle id committed.

---

## Phase 0 — Scaffold

### T0.1 — Repo skeleton and licence  _(deps: none)_
- `LICENSE` (MIT, current year), `README.md` skeleton (what/why/install/status: pre-alpha),
  `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md` (short), `.editorconfig`.
- Extend `.gitignore`: `bench/out/`, `bench/local.env`, `DemoApp/*.xcodeproj`, `*.jpeg`.
- DoD: `git status` clean after a `swift build` attempt; README states the pinned triple
  (agent-device 0.20.10 / Xcode 26.6 / iOS 26.5) and links the three planning docs.

### T0.2 — SwiftPM package  _(deps: T0.1)_
- Root `Package.swift`: swift-tools 6.0, platforms `.macOS(.v14)`, one dependency
  (`swift-argument-parser`), targets `SimProbeCore`, `simprobe`, `SimProbeCoreTests`,
  `SimProbeCLITests`. Placeholder sources so the graph resolves.
- RED: `SimProbeCoreTests/PackageSmokeTests.swift` → `testCoreModuleIsImportable`.
- DoD: `swift build` and `swift test` both succeed locally with one trivially passing test.

### T0.3 — CI workflow  _(deps: T0.2)_
- `.github/workflows/ci.yml` on `macos-15`: `swift build`, `swift test
  --enable-code-coverage`, `swift format lint --recursive Sources Tests`.
- Second job `hygiene`: fail on any match of `dlopen`, `AXPTranslator`, `SimulatorKit`,
  `pkill`, `/Users/`, or a UDID regex `[0-9A-F]{8}-[0-9A-F]{4}-` in tracked files.
- DoD: both jobs green on a PR with no simulator available; hygiene job proven by a scratch
  commit containing `pkill` that turns it red, then reverted.

---

## Phase 1 — Core image maths (no simulator, no IO)

### T1.1 — `GrayFrame` and downscale  _(deps: T0.2)_
- RED: `ThumbnailTests.swift` →
  `testDownscaleProducesRequestedDimensions`,
  `testDownscaleOfUniformImageIsUniform`,
  `testDownscalePreservesRelativeBrightnessOrdering`,
  `testDownscaleIsDeterministicForSameInput`.
- Build `GrayFrame` (immutable struct, `[UInt8]` + width/height) and
  `Thumbnail.downscale(_:to:)` on CGImage via CoreGraphics, default target 40x87.
- DoD: tests green; fixtures generated in-test with CoreGraphics (no committed images, `*.png`
  is git-ignored); no IO in `SimProbeCore`; file coverage ≥ 90%.

### T1.2 — `meanAbsoluteDifference`  _(deps: T1.1)_
- RED: `FrameDiffTests.swift` →
  `testIdenticalFramesDiffZero`,
  `testBlackVsWhiteFramesDiffIsMaximum`,
  `testMismatchedSizesThrowSizeMismatch`,
  `testSmallPerturbationStaysUnderDefaultTolerance` (asserts ≤ 0.03, the measured idle band),
  `testScreenTransitionMagnitudeExceedsTolerance` (synthetic transition, asserts ≥ 5).
- DoD: tests green; the 0.5 default tolerance is a named constant with a doc comment citing
  the measured 0.03-vs-11.01 separation.

### T1.3 — `StabilityEvaluator` state machine  _(deps: T1.2)_
- RED: `StabilityEvaluatorTests.swift` →
  `testSettlesAfterThreeConsecutiveQuietPolls`,
  `testDoesNotSettleWhileDiffExceedsTolerance`,
  `testReportsTimedOutWithLastDiffAndPollCount`,
  `testMicroAnimationSequenceStillSettles` (feeds the measured 0.00–0.03 band),
  `testFirstPollNeverReportsSettled` (needs two frames to have a diff at all).
- Pure fold over a diff sequence; the poll loop is **not** here.
- DoD: tests green; verdict type is an enum carrying `afterMs` and `polls`.

### T1.4 — `MotionTimeline` + `ScreenshotBudget`  _(deps: T1.2)_
- RED: `MotionTimelineTests.swift` →
  `testFormatsCompactTimelineWithSettlePoint`,
  `testJSONEncodingMatchesDocumentedShape`,
  `testTimelineWithNoSettlePointReportsNotSettled`.
  `ScreenshotBudgetTests.swift` →
  `testDerivesPointScaleFromPixelAndPointSize` (1206x2622 px / 402x874 pt → 3.0),
  `testEstimatesVisionTokensAsWidthTimesHeightOverSevenFifty`,
  `testDefaultTargetWidthEqualsLogicalPointWidth`.
- DoD: tests green; the scale factor is derived, never hardcoded.

---

## Phase 2 — CLI verbs

### T2.1 — IO protocols and fakes  _(deps: T1.3)_
- Define `ScreenCapturing`, `DeviceListing`, `Clock`. Real impls wrap `xcrun simctl` via
  `Process`; capture goes to a temp file (`simctl io … screenshot -` writes a file named `-`,
  it does **not** stream) deleted in a `defer`.
- RED: `SimProbeCLITests/FakesTests.swift` →
  `testScriptedCaptureReturnsFramesInOrder`,
  `testVirtualClockAdvancesOnSleep`,
  `testCaptureFailureSurfacesAsProbeErrorCaptureFailed`.
- DoD: fakes usable by every later verb test; no test touches a real simulator.

### T2.2 — `wait-stable`  _(deps: T2.1)_
- RED: `WaitStableCommandTests.swift` →
  `testPrintsStableAfterElapsedAndPollCount` (asserts the exact line
  `stable after 180ms (3 polls, last diff 0.01, tol 0.50)`),
  `testExitsThreeOnTimeout`,
  `testJSONOutputMatchesDocumentedKeys`,
  `testRespectsCustomTolerance`,
  `testStopsPollingImmediatelyOnceSettled`.
- DoD: deterministic under `VirtualClock` + `ScriptedCapture`; exit codes per `02-architecture.md` §5.

### T2.3 — `motion`  _(deps: T2.2)_
- RED: `MotionCommandTests.swift` →
  `testEmitsNoImageBytesOnStdout` (asserts stdout is ASCII and < 500 bytes),
  `testTimelineUsesActualSampleTimestamps`,
  `testKeepFramesWritesOnePNGPerSampleToGivenDirectory`,
  `testReportsMeasuredFPS`.
- DoD: `--keep-frames` is the only path that writes images; default writes none.

### T2.4 — `shot`  _(deps: T2.1, T1.4)_
- RED: `ShotCommandTests.swift` →
  `testDefaultWidthIsLogicalPointWidth`,
  `testEncodesJPEGAtRequestedQuality`,
  `testSummaryLineReportsPixelSizeScaleBytesAndTokenEstimate`,
  `testRejectsWidthLargerThanSourcePixelWidth`.
- DoD: output ≤ 500 vision tokens on a standard iPhone frame (PRD A4).

### T2.5 — `devices` and `diff`  _(deps: T2.1)_
- RED: `DevicesCommandTests.swift` →
  `testParsesSimctlListJSONIntoDevices`,
  `testMarksBootedDevices`,
  `testResolvesUniqueNameToUDID`,
  `testAmbiguousNameExitsTwoWithBothCandidates`.
  `DiffCommandTests.swift` →
  `testIdenticalFilesExitZero`,
  `testDifferentFilesExitFour`,
  `testUnreadableFileExitsFive`.
- DoD: tests green; the `simctl list devices --json` fixture is a trimmed, **anonymised** string
  in the test file; no real UDID anywhere in the repo.

### T2.6 — Error surface, `--json`, and root command wiring  _(deps: T2.2–T2.5)_
- `ProbeError` enum, exit-code mapping, `{"error":{...}}` on stdout under `--json`, `--udid`
  resolution (single booted device, else exit 2), `--version`.
- RED: `ErrorSurfaceTests.swift` →
  `testEveryProbeErrorMapsToDocumentedExitCode`,
  `testJSONModeEmitsErrorObjectOnStdout`,
  `testHumanModeEmitsMessageOnStderrAndNothingOnStdout`.
- DoD: `swift test` coverage on `SimProbeCore` ≥ 80% (PRD A6); README usage block matches
  actual `--help` output.

### T2.7 — Live smoke tests (tagged, skipped in CI)  _(deps: T2.6)_
- Tests guarded by `SIMPROBE_LIVE=1` that boot nothing but require one booted simulator:
  `testLiveWaitStableSettlesOnStaticHomeScreen`,
  `testLiveShotMatchesReportedPointSize`,
  `testLiveDevicesListsAtLeastOneBootedDevice`.
- **Also verify agent-device `--udid <udid>` targeting** (PRD R5); record the result in
  `skill/references/pitfalls.md`, or document the name + snapshot-assertion fallback if it
  fails. Use `open`/`close`/`daemon stop [--clean]` only — never `pkill`.
- DoD: green locally with a booted simulator; skipped and green in CI.

---

## Phase 3 — Skill

### T3.1 — `SKILL.md`  _(deps: T2.6 (so `simprobe`'s real surface is documented, not guessed))_
- ~120 lines: escalation ladder with the measured byte/token numbers, the settle decision rule
  (bare `press` ~1.5 s vs `--settle` 1.5–3.4 s, quiet 500 ms / timeout 10 s defaults), the five
  hard don'ts, pointers into `references/`, and the pinned-triple header.
- DoD: under 130 lines; every agent-device flag it names was verified against
  `agent-device help <command>` at 0.20.10; no personal path or bundle id.

### T3.2 — `references/agent-device-cheatsheet.md`  _(deps: T3.1)_
- `open --launch-args` (repeatable), `snapshot [-i] [--diff]`,
  `press/fill/longpress/scroll/back --settle`, `wait <ms>|text|@ref|<selector>|stable`,
  `is`/`get`/`find`, `screenshot --pixel-density/--scale/--overlay-refs`, `diff snapshot`,
  `session list`, `close`, `daemon stop [--clean]`, `--cost`, `--json`, `--level
  digest|default|full` (global flag), `AGENT_DEVICE_SESSION`,
  `AGENT_DEVICE_SCREENSHOT_SCALE`, `AGENT_DEVICE_SESSION_LOCK` (marked unverified).
- DoD: every line traceable to `agent-device help` output; nothing invented.

### T3.3 — `references/pitfalls.md`  _(deps: T3.1)_
- REAPER GUARD (three surviving processes, time-bounded by the ~5 min runner idle-stop
  default, what `pkill` costs, recovery = reboot the sim, `daemon stop --clean` as the
  sanctioned reclaim), the `close` lease leak and reopen recipe, the cwd-hash implicit
  session, `--device` names vs `--udid`, AZERTY (`fill` yes / HID `type` no — the sim-use
  0.13.0 Cmd+HID('a') = Cmd+Q incident, not agent-device), the field-clear recipe (app clear
  button, or `press @<delete-key> --count N` on the keyboard AX element, unverified e2e /
  locale-dependent label), `batch` excluding `press`/`fill`, `fill @ref ""` rejected,
  degradation under host load (`main thread execution timed out`).
- DoD: each entry states the observed symptom, the cause, and the workaround, in that order.

### T3.4 — `references/simprobe.md` + skill install docs  _(deps: T3.1, T2.6)_
- When to reach for `simprobe` over `agent-device wait stable` (rendering vs AX quiescence;
  no session required; independent control probe), one worked example per verb.
- README section: `cp -r skill ~/.claude/skills/mobilecontroller`.
- DoD: examples copy-pasteable and consistent with `--help`.

---

## Phase 4 — Bench and DemoApp

### T4.1 — Bench library  _(deps: T2.6)_
- `bench/lib/`: timing, stdout byte counting, `est_tokens = bytes/4`, loadavg read, control
  probe (one `simctl io … screenshot`), CSV writer, markdown renderer.
- RED (shell smoke tests via `bats` or a plain `bench/lib/test.sh`):
  `test_csv_header_matches_documented_columns`,
  `test_est_tokens_is_bytes_over_four`,
  `test_loadavg_column_is_numeric`,
  `test_control_probe_records_milliseconds`.
- DoD: runnable with a stubbed command; teardown path contains `close` + `daemon stop --clean`
  and a comment forbidding `pkill`.

### T4.2 — Settings flow + `run.sh`  _(deps: T4.1)_
- `bench/flows/settings-observe-act.sh`: open `com.apple.Preferences`, digest snapshot, press a
  row, `-i` snapshot, `wait-stable`, screenshot — repeated `--repeat N`.
- DoD: `bench/run.sh --target settings` produces `bench/out/<ts>/results.csv` and a markdown
  table on a stock machine with only a booted simulator.

### T4.3 — DemoApp  _(deps: T0.1)_
- SwiftUI app: tab bar (2–3 tabs), a ~40-row list, a text field, and one button driving an
  explicit 300 ms animated transition. Accessibility identifiers on every interactive element.
  `project.yml` for XcodeGen; **no `.xcodeproj` committed**.
- DoD: `xcodegen generate && xcodebuild -scheme DemoApp -destination 'generic/platform=iOS
  Simulator' build` succeeds; the app contains no personal data and no network calls.

### T4.4 — DemoApp flow + published numbers  _(deps: T4.2, T4.3)_
- `bench/flows/demoapp-*.sh` including the fill/clear path and a `motion` measurement against
  the known 300 ms transition (ground truth for PRD A2).
- Run both targets, paste the markdown table into the README under "Measured on…", with the
  loadavg and control-probe columns visible.
- DoD: README numbers regenerable by one command; the caveat about host-load inflation
  (2–10x) is printed in the table header, not buried.

---

## Phase 5 — Docs, sanitizer, publish

### T5.1 — README  _(deps: T3.4, T4.4)_
- Problem, the adopt-and-complement decision, install, the three deliverables, the measured
  table, the pinned triple, Future work, the upstream-issues list, MIT, credit to
  callstack/agent-device.
- DoD: a reader who has never seen the research understands why `simprobe` exists in 60 seconds.

### T5.2 — Sanitizer pass  _(deps: T5.1)_
- Grep every tracked file for: a UDID regex, `/Users/`, the maintainer's username, the private
  app's bundle id and fixture names, any personal display name, `pkill`, `dlopen`. Confirm
  `.local/` is ignored and unreferenced, and that `bench/local.env` is ignored with a committed
  `bench/local.env.example`.
- DoD: zero hits; the grep list ships as `scripts/sanitize-check.sh`, wired into CI hygiene.

### T5.3 — Upstream issues  _(deps: T2.7 (so `--udid` is settled))_
- File the five issues from PRD §10 on callstack/agent-device, each with a reproducer and
  observed-vs-expected output. Link them from the README.
- DoD: five issue URLs in the README.

### T5.4 — Publish  _(deps: T5.2, T5.3)_
- Tag `v0.1.0`, push public, enable Actions, add topics (`ios-simulator`, `claude-code`,
  `swiftui`, `agent-tools`).
- DoD: a clean clone on another machine reaches green `swift test` and a working
  `bench/run.sh --target settings` with no edits.

---

## Dependency summary

```
T0.1 → T0.2 → T0.3
T0.2 → T1.1 → T1.2 → T1.3 → T2.1 → T2.2 → T2.3
                  └→ T1.4 ──────────────→ T2.4
              T2.1 ─────────────────────→ T2.5
     T2.2..T2.5 → T2.6 → T2.7 → T5.3
              T2.6 → T3.1 → {T3.2, T3.3, T3.4}
              T2.6 → T4.1 → T4.2 ┐
              T0.1 → T4.3 ───────┴→ T4.4 → T5.1 → T5.2 → T5.4
```

Parallelisable once T2.1 lands: T2.2 / T2.4 / T2.5; T4.3 is independent of everything after T0.1.
