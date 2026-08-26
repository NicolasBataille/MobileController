import SimProbeCore
import XCTest

final class StabilityEvaluatorTests: XCTestCase {

    func testSettlesAfterThreeConsecutiveQuietPolls() {
        let evaluator = StabilityEvaluator(quietPollsRequired: 3)

        let settled = fold(evaluator, diffs: [(60, 0.02), (120, 0.01), (180, 0.01)])

        XCTAssertEqual(settled.verdict, .settled(afterMs: 180, polls: 3))
    }

    func testDoesNotSettleWhileDiffExceedsTolerance() {
        let evaluator = StabilityEvaluator(quietPollsRequired: 3, timeoutMs: 4_000)

        let moving = fold(evaluator, diffs: [(60, 11.0), (120, 0.01), (180, 3.2), (240, 0.01)])

        XCTAssertNil(moving.verdict)
        XCTAssertEqual(moving.polls, 4)
        XCTAssertEqual(moving.quietPolls, 1)
    }

    func testReportsTimedOutWithLastDiffAndPollCount() {
        let evaluator = StabilityEvaluator(quietPollsRequired: 3, timeoutMs: 1_000)

        let expired = fold(
            evaluator,
            diffs: [(200, 9.4), (400, 6.1), (600, 4.8), (800, 3.9), (1_004, 3.2)]
        )

        XCTAssertEqual(expired.verdict, .timedOut(lastDiff: 3.2, polls: 5))
        XCTAssertEqual(expired.elapsedMs, 1_004)
    }

    /// The measured idle band of a screen carrying a perpetual micro-animation.
    func testMicroAnimationSequenceStillSettles() {
        let evaluator = StabilityEvaluator(quietPollsRequired: 3)

        let settled = fold(evaluator, diffs: [(60, 0.00), (120, 0.03), (180, 0.02)])

        XCTAssertEqual(settled.verdict, .settled(afterMs: 180, polls: 3))
    }

    /// One frame is a baseline, not a measurement: there is nothing yet to compare it against.
    func testFirstPollNeverReportsSettled() throws {
        let evaluator = StabilityEvaluator(quietPollsRequired: 1)
        let frame = try uniformFrame(luminance: 40)

        let afterOneFrame = try evaluator.observing(frame, atMs: 0)

        XCTAssertNil(afterOneFrame.verdict)
        XCTAssertEqual(afterOneFrame.polls, 0)
    }

    func testObservingFramesComputesTheDiffAgainstThePreviousFrame() throws {
        let evaluator = StabilityEvaluator(quietPollsRequired: 1, startedAtMs: 0)

        let settled = try evaluator
            .observing(try uniformFrame(luminance: 40), atMs: 0)
            .observing(try uniformFrame(luminance: 40), atMs: 60)

        XCTAssertEqual(settled.verdict, .settled(afterMs: 60, polls: 1))
        XCTAssertEqual(try XCTUnwrap(settled.lastDiff), 0, accuracy: 1e-9)
    }

    func testObservingMismatchedFrameSizesThrows() throws {
        let evaluator = StabilityEvaluator()
        let big = try uniformFrame(luminance: 10)
        let tiny = FrameSize(width: 2, height: 2)
        let small = try GrayFrame(size: tiny, pixels: [UInt8](repeating: 0, count: tiny.pixelCount))

        let seeded = try evaluator.observing(big, atMs: 0)

        XCTAssertThrowsError(try seeded.observing(small, atMs: 60)) {
            XCTAssertEqual($0 as? FrameError, .sizeMismatch(big.size, tiny))
        }
    }

    func testTimeoutVerdictIsAvailableWithoutAFurtherPoll() {
        let evaluator = StabilityEvaluator(quietPollsRequired: 3, timeoutMs: 1_000)

        let moving = fold(evaluator, diffs: [(200, 9.4), (400, 6.1)])

        XCTAssertNil(moving.verdict)
        XCTAssertEqual(moving.timeoutVerdict, .timedOut(lastDiff: 6.1, polls: 2))
    }

    func testRespectsACustomTolerance() {
        let strict = StabilityEvaluator(tolerance: 0.005, quietPollsRequired: 2)

        let stillMoving = fold(strict, diffs: [(60, 0.02), (120, 0.01)])

        XCTAssertNil(stillMoving.verdict)
        XCTAssertEqual(stillMoving.quietPolls, 0)
    }

    private func fold(
        _ evaluator: StabilityEvaluator,
        diffs: [(Int, Double)]
    ) -> StabilityEvaluator {
        diffs.reduce(evaluator) { $0.observing(diff: $1.1, atMs: $1.0) }
    }

    private func uniformFrame(luminance: UInt8) throws -> GrayFrame {
        let size = Thumbnail.defaultSize
        return try GrayFrame(
            size: size,
            pixels: [UInt8](repeating: luminance, count: size.pixelCount)
        )
    }
}
