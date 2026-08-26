import ArgumentParser
import CoreGraphics
import Foundation
import SimProbeCore
import XCTest

@testable import SimProbeCLI

/// Stands in for `simctl io … screenshot <file>`: writes a real PNG where it was told to.
private final class PNGWritingRunner: ProcessRunning {

    private let image: CGImage

    init(image: CGImage) { self.image = image }

    func run(_ executable: String, _ arguments: [String], deadlineMs: Int) throws
        -> ProcessResult
    {
        guard let path = arguments.last else {
            return ProcessResult(status: 1, standardOutput: Data(), standardError: "no path")
        }
        try ImageEncoder.writePNG(image, to: URL(fileURLWithPath: path))
        return ProcessResult(status: 0, standardOutput: Data(), standardError: "")
    }
}

/// The thin adapters between the verbs and the outside world.
final class AdapterTests: XCTestCase {

    func testReportingPassesSuccessThroughAndRaisesResultCodes() throws {
        let output = RecordingOutput()

        XCTAssertNoThrow(try CommandExit.reporting(json: false, to: output) { _ in 0 })

        XCTAssertThrowsError(try CommandExit.reporting(json: false, to: output) { _ in 4 }) {
            XCTAssertEqual($0 as? ExitCode, ExitCode(4))
        }
        // A result code prints nothing extra: the verb already wrote its line.
        XCTAssertEqual(output.outLines, [])
    }

    func testReportingRendersProbeErrorsAndExitsWithTheirCode() {
        let output = RecordingOutput()

        XCTAssertThrowsError(
            try CommandExit.reporting(json: false, to: output) { _ in
                throw ProbeError.noBootedDevice
            }
        ) {
            XCTAssertEqual($0 as? ExitCode, ExitCode(2))
        }

        XCTAssertEqual(output.outLines, [])
        XCTAssertEqual(output.errorLines.count, 1)
    }

    func testSystemClockIsMonotonicAndSleeps() {
        let clock = SystemClock()

        let before = clock.nowMs
        clock.sleep(ms: 0)
        XCTAssertGreaterThanOrEqual(clock.nowMs, before)
        clock.sleep(ms: 12)
        XCTAssertGreaterThanOrEqual(clock.nowMs - before, 10)
    }

    func testFrameDifferenceOfMismatchedSizesIsExitFive() throws {
        let small = try GrayFrame(size: FrameSize(width: 2, height: 2), pixels: [0, 0, 0, 0])
        let large = try GrayFrame(
            size: FrameSize(width: 2, height: 3), pixels: Array(repeating: 0, count: 6))

        XCTAssertThrowsError(try Frames.difference(small, large)) {
            XCTAssertEqual(($0 as? ProbeError)?.exitCode, 5)
        }
    }

    func testSimctlLocationFailureIsAnEnvironmentError() {
        let failing = StubProcessRunner(
            result: ProcessResult(status: 1, standardOutput: Data(), standardError: "no xcrun")
        )

        XCTAssertThrowsError(try Simctl.locate(runner: failing)) {
            XCTAssertEqual(($0 as? ProbeError)?.exitCode, 2)
        }
        XCTAssertEqual(
            try Simctl.locate(runner: StubProcessRunner(standardOutput: "/x/simctl\n")), "/x/simctl"
        )
    }

    func testDeviceListingFailureIsAnEnvironmentError() {
        let failing = StubProcessRunner(
            result: ProcessResult(
                status: 2, standardOutput: Data(), standardError: "device set locked")
        )
        let lister = SimctlDeviceLister(simctl: "/usr/bin/true", runner: failing)

        XCTAssertThrowsError(try lister.devices()) {
            XCTAssertEqual(($0 as? ProbeError)?.exitCode, 2)
        }
        let malformed = SimctlDeviceLister(
            simctl: "/usr/bin/true",
            runner: StubProcessRunner(standardOutput: "not json")
        )
        XCTAssertThrowsError(try malformed.devices()) {
            XCTAssertEqual(($0 as? ProbeError)?.exitCode, 2)
        }
    }

    func testRuntimeLabelFallsBackToTheRawIdentifier() {
        XCTAssertEqual(
            SimctlDeviceLister.runtimeLabel("com.apple.CoreSimulator.SimRuntime.watchOS-11-0"),
            "watchOS 11.0"
        )
        XCTAssertEqual(SimctlDeviceLister.runtimeLabel("unavailable"), "unavailable")
    }

    /// A capture must survive the temporary file it came from being deleted.
    ///
    /// `CGImageSourceCreateWithURL` decodes lazily: the returned `CGImage` keeps referring to
    /// the file, so a capture whose temporary directory is removed in a `defer` hands back an
    /// image that draws as solid black. Every downstream measurement then reads 0.00 and every
    /// screen looks settled.
    func testCaptureSurvivesRemovalOfTheTemporaryFile() throws {
        let source = try TestFrames.gray(width: 60, height: 40) { x, _ in x < 30 ? 0 : 255 }
        let capture = SimctlScreenCapture(
            simctl: "/usr/bin/true", runner: PNGWritingRunner(image: source))

        let image = try capture.capture(udid: Fixtures.udid)

        let frame = try Frames.thumbnail(of: image)
        let mean = frame.pixels.reduce(0) { $0 + Int($1) } / frame.pixels.count
        XCTAssertGreaterThan(mean, 40, "the capture decoded as black after its file was removed")
    }

    /// A child that never exits must not hang the CLI forever.
    ///
    /// `waitUntilExit()` has no deadline, so a wedged `simctl` used to pin the process
    /// indefinitely - and `wait-stable --timeout` could not bound its own wall time.
    func testProcessRunnerKillsChildAfterDeadline() throws {
        // A marker unique to this child, so the liveness check below cannot match some other
        // `sleep` on the machine.
        let marker = "simprobe-deadline-\(UUID().uuidString)"
        let startedAt = Date()

        XCTAssertThrowsError(
            try SystemProcessRunner().run(
                "/bin/sh", ["-c", "sleep 30 # \(marker)"], deadlineMs: 200)
        ) { error in
            XCTAssertEqual((error as? ProbeError)?.exitCode, 2)
            XCTAssertTrue("\(error)".contains("timed out"), "\(error)")
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2, "the deadline did not fire")
        XCTAssertFalse(isRunning(marker), "the child outlived the run that spawned it")
    }

    func testSystemProcessRunnerHandlesStdoutLargerThanPipeBuffer() throws {
        // 200 KB is comfortably past the 64 KB pipe buffer that a Pipe-based runner deadlocks
        // on: `simctl list devices --json` crosses it on any real machine.
        let result = try SystemProcessRunner().run(
            "/bin/sh", ["-c", "yes x | head -c 200000"])

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.standardOutput.count, 200_000)
    }

    /// True while any process still carries `marker` in its command line.
    private func isRunning(_ marker: String) -> Bool {
        let found = try? SystemProcessRunner().run("/usr/bin/pgrep", ["-f", marker])
        return found?.status == 0
    }

    func testSystemProcessRunnerCapturesBothStreams() throws {
        let result = try SystemProcessRunner().run(
            "/bin/sh", ["-c", "echo out; echo err >&2; exit 7"])

        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.standardOutputText, "out\n")
        XCTAssertEqual(result.failureDetail, "err")
    }
}
