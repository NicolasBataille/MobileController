import Foundation
import SimProbeCore
import XCTest

@testable import SimProbeCLI

/// `motion` under a clock that only advances when a capture "costs" time, which is how the
/// sample timestamps below can be asserted exactly while still being *measured* values.
final class MotionCommandTests: XCTestCase {

    /// The measured `simctl` screenshot floor, give or take.
    private let captureCostMs = 205

    func testEmitsNoImageBytesOnStdout() throws {
        let result = try runMotion()

        let stdout = result.output.out
        XCTAssertTrue(stdout.allSatisfy(\.isASCII), "stdout carried non-ASCII bytes")
        XCTAssertLessThan(Data(stdout.utf8).count, 500)
        XCTAssertEqual(result.output.errorLines, [])
    }

    func testTimelineUsesActualSampleTimestamps() throws {
        let result = try runMotion()

        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(
            result.output.out,
            "t=205 1.00, 410 1.00, 615 0.01  ->  settled@615ms (3 samples, 4.9 fps)"
        )
    }

    func testKeepFramesWritesOnePNGPerSampleToGivenDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "simprobe-motion-test-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try runMotion(keepFrames: directory)

        let written = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        // The sample index leads, zero-padded: two captures can land in the same millisecond
        // on a fast host, and a name built from the timestamp alone would then lose a frame.
        XCTAssertEqual(
            written,
            ["frame-000-205ms.png", "frame-001-410ms.png", "frame-002-615ms.png"]
        )
        XCTAssertEqual(result.code, 0)
    }

    func testDefaultRunWritesNoFiles() throws {
        let result = try runMotion()

        XCTAssertEqual(result.code, 0)
        XCTAssertFalse(result.output.out.contains(".png"))
    }

    func testReportsMeasuredFPS() throws {
        let timeline = try runMotionTimeline()

        // Three samples spanning 205..615 ms: two intervals over 410 ms is 4.878 fps.
        XCTAssertEqual(timeline["fps"] as? Double, 4.9)
        XCTAssertEqual(timeline["settledAtMs"] as? Int, 615)
        XCTAssertEqual((timeline["samples"] as? [[String: Any]])?.count, 3)
    }

    // MARK: Harness

    private struct MotionResult {
        let code: Int32
        let output: RecordingOutput
    }

    private func runMotion(
        keepFrames: URL? = nil,
        json: Bool = false
    ) throws -> MotionResult {
        let output = RecordingOutput()
        let clock = VirtualClock()
        let capture = ScriptedCapture(frames: try frames(), advancing: clock, costMs: captureCostMs)
        let options = MotionOptions(
            udid: Fixtures.udid,
            durationMs: 600,
            keepFramesDirectory: keepFrames,
            json: json
        )
        let code = try MotionRunner(options: options)
            .run(in: ProbeEnvironment(capture: capture, clock: clock, output: output))
        return MotionResult(code: code, output: output)
    }

    private func runMotionTimeline() throws -> [String: Any] {
        let result = try runMotion(json: true)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.output.out.utf8)) as? [String: Any]
        )
    }

    /// A baseline, two frames a full luminance step away from their predecessor, then one that
    /// has all but settled: diffs of 1.00, 1.00 and 0.01.
    private func frames() throws -> [CGImage] {
        [
            try TestFrames.thumbnail(base: 100),
            try TestFrames.thumbnail(base: 101),
            try TestFrames.thumbnail(base: 100),
            try TestFrames.thumbnail(base: 100, raisedPixels: 35),
            try TestFrames.thumbnail(base: 100, raisedPixels: 35),
        ]
    }
}
