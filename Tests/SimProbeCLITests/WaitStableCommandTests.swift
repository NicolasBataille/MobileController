import Foundation
import SimProbeCore
import XCTest

@testable import SimProbeCLI

/// `wait-stable` driven entirely by a scripted frame sequence and a clock that only moves when
/// the loop sleeps, so every assertion below is about the poll loop and nothing else.
final class WaitStableCommandTests: XCTestCase {

    func testPrintsStableAfterElapsedAndPollCount() throws {
        let output = RecordingOutput()
        let clock = VirtualClock()
        // Three quiet comparisons; the last pair differs by exactly 35 / (40 * 87) = 0.0101.
        let capture = ScriptedCapture(frames: [
            try TestFrames.thumbnail(base: 100),
            try TestFrames.thumbnail(base: 100),
            try TestFrames.thumbnail(base: 100),
            try TestFrames.thumbnail(base: 100, raisedPixels: 35),
        ])

        let code = try WaitStableRunner(options: .init(udid: Fixtures.udid))
            .run(in: ProbeEnvironment(capture: capture, clock: clock, output: output))

        XCTAssertEqual(code, 0)
        XCTAssertEqual(output.out, "stable after 180ms (3 polls, last diff 0.01, tol 0.50)")
        XCTAssertEqual(output.errorLines, [])
    }

    func testExitsThreeOnTimeout() throws {
        let output = RecordingOutput()
        let clock = VirtualClock()
        let capture = ScriptedCapture(frames: try alternatingFrames(count: 12))

        let code = try WaitStableRunner(options: .init(udid: Fixtures.udid, timeoutMs: 300))
            .run(in: ProbeEnvironment(capture: capture, clock: clock, output: output))

        XCTAssertEqual(code, 3)
        XCTAssertEqual(output.out, "not stable after 300ms (5 polls, last diff 255.00, tol 0.50)")
    }

    func testSinglePollIsReportedInTheSingular() throws {
        let output = RecordingOutput()
        let capture = ScriptedCapture(frames: try alternatingFrames(count: 4))

        let code = try WaitStableRunner(options: .init(udid: Fixtures.udid, timeoutMs: 60))
            .run(in: ProbeEnvironment(capture: capture, clock: VirtualClock(), output: output))

        XCTAssertEqual(code, 3)
        XCTAssertEqual(output.out, "not stable after 60ms (1 poll, last diff 255.00, tol 0.50)")
    }

    func testJSONOutputMatchesDocumentedKeys() throws {
        let output = RecordingOutput()
        let capture = ScriptedCapture(
            frames: try Array(repeating: TestFrames.thumbnail(base: 8), count: 4))

        let code = try WaitStableRunner(options: .init(udid: Fixtures.udid, json: true))
            .run(in: ProbeEnvironment(capture: capture, clock: VirtualClock(), output: output))

        XCTAssertEqual(code, 0)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.out.utf8)) as? [String: Any]
        )
        XCTAssertEqual(
            Set(payload.keys),
            ["stable", "elapsedMs", "polls", "lastDiff", "tol", "udid"]
        )
        XCTAssertEqual(payload["stable"] as? Bool, true)
        XCTAssertEqual(payload["elapsedMs"] as? Int, 180)
        XCTAssertEqual(payload["polls"] as? Int, 3)
        XCTAssertEqual(payload["udid"] as? String, Fixtures.udid)
    }

    func testRespectsCustomTolerance() throws {
        // Every consecutive pair differs by exactly 1.0: quiet at tol 2.0, never at tol 0.5.
        let frames = try (0..<12).map {
            try TestFrames.thumbnail(base: $0.isMultiple(of: 2) ? 100 : 101)
        }
        let environment = { (capture: ScriptedCapture) in
            ProbeEnvironment(capture: capture, clock: VirtualClock(), output: RecordingOutput())
        }

        let loose = ScriptedCapture(frames: frames)
        let looseOutput = RecordingOutput()
        let looseCode = try WaitStableRunner(options: .init(udid: Fixtures.udid, tolerance: 2))
            .run(in: ProbeEnvironment(capture: loose, clock: VirtualClock(), output: looseOutput))
        XCTAssertEqual(looseCode, 0)
        XCTAssertEqual(looseOutput.out, "stable after 180ms (3 polls, last diff 1.00, tol 2.00)")

        let strict = ScriptedCapture(frames: frames)
        let strictCode = try WaitStableRunner(options: .init(udid: Fixtures.udid, timeoutMs: 300))
            .run(in: environment(strict))
        XCTAssertEqual(strictCode, 3)
    }

    func testStopsPollingImmediatelyOnceSettled() throws {
        let capture = ScriptedCapture(
            frames: try Array(repeating: TestFrames.thumbnail(base: 60), count: 20)
        )

        _ = try WaitStableRunner(options: .init(udid: Fixtures.udid))
            .run(
                in: ProbeEnvironment(
                    capture: capture, clock: VirtualClock(), output: RecordingOutput()))

        // One baseline plus exactly the three quiet comparisons the verdict needs.
        XCTAssertEqual(capture.captureCount, 4)
    }

    func testParsesDurationSuffixes() throws {
        XCTAssertEqual(try Milliseconds.parse("60ms"), 60)
        XCTAssertEqual(try Milliseconds.parse("4s"), 4_000)
        XCTAssertEqual(try Milliseconds.parse("1.5s"), 1_500)
        XCTAssertEqual(try Milliseconds.parse("250"), 250)
    }

    func testRejectsUnparseableDuration() {
        for text in ["", "soon", "-3s", "4m"] {
            XCTAssertThrowsError(try Milliseconds.parse(text), text) { error in
                XCTAssertEqual((error as? ProbeError)?.exitCode, 1)
            }
        }
    }

    private func alternatingFrames(count: Int) throws -> [CGImage] {
        try (0..<count).map { try TestFrames.thumbnail(base: $0.isMultiple(of: 2) ? 0 : 255) }
    }
}
