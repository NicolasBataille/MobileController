import ArgumentParser
import Foundation
import SimProbeCore
import XCTest

@testable import SimProbeCLI

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

    func testSystemProcessRunnerCapturesBothStreams() throws {
        let result = try SystemProcessRunner().run(
            "/bin/sh", ["-c", "echo out; echo err >&2; exit 7"])

        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.standardOutputText, "out\n")
        XCTAssertEqual(result.failureDetail, "err")
    }
}
