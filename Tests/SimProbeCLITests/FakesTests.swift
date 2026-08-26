import CoreGraphics
import XCTest

@testable import SimProbeCLI

/// Covers the injected doubles every later verb test is built on, plus the one real IO
/// adapter whose failure path they all rely on.
final class FakesTests: XCTestCase {

    func testScriptedCaptureReturnsFramesInOrder() throws {
        let capture = ScriptedCapture(frames: [
            try TestFrames.uniform(width: 4, height: 8, luminance: 10),
            try TestFrames.uniform(width: 6, height: 8, luminance: 20),
            try TestFrames.uniform(width: 8, height: 8, luminance: 30),
        ])

        let widths = try (0..<3).map { _ in try capture.capture(udid: Fixtures.udid).width }

        XCTAssertEqual(widths, [4, 6, 8])
        XCTAssertEqual(capture.captureCount, 3)
        XCTAssertEqual(capture.requestedUdids, Array(repeating: Fixtures.udid, count: 3))
    }

    func testVirtualClockAdvancesOnSleep() {
        let clock = VirtualClock(startMs: 1_000)

        XCTAssertEqual(clock.nowMs, 1_000)
        clock.sleep(ms: 60)
        XCTAssertEqual(clock.nowMs, 1_060)
        clock.sleep(ms: 140)
        XCTAssertEqual(clock.nowMs, 1_200)
        XCTAssertEqual(clock.sleeps, [60, 140])
    }

    func testCaptureFailureSurfacesAsProbeErrorCaptureFailed() {
        let runner = StubProcessRunner(
            result: ProcessResult(
                status: 1, standardOutput: Data(), standardError: "no such device")
        )
        let capture = SimctlScreenCapture(simctl: "/usr/bin/false", runner: runner)

        XCTAssertThrowsError(try capture.capture(udid: Fixtures.udid)) { error in
            guard let probeError = error as? ProbeError else {
                return XCTFail("expected a ProbeError, got \(error)")
            }
            XCTAssertEqual(probeError.exitCode, 5)
            guard case .captureFailed(let detail) = probeError else {
                return XCTFail("expected .captureFailed, got \(probeError)")
            }
            XCTAssertTrue(detail.contains("no such device"), detail)
        }
    }
}
