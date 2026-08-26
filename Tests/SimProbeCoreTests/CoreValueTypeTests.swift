import SimProbeCore
import XCTest

/// Covers the value types' accessors and the error surface's messages.
///
/// Error descriptions are user-facing output, not incidental debugging text: `simprobe` prints
/// them on stderr as the one line explaining a failure, so they are asserted like any other
/// output.
final class CoreValueTypeTests: XCTestCase {

    // MARK: FrameSize

    func testFrameSizeReportsPixelCountAndPositivity() {
        let size = FrameSize(width: 40, height: 87)

        XCTAssertEqual(size.pixelCount, 3_480)
        XCTAssertTrue(size.isPositive)
        XCTAssertFalse(FrameSize(width: 0, height: 87).isPositive)
        XCTAssertFalse(FrameSize(width: 40, height: -1).isPositive)
    }

    func testFrameSizeDescribesItselfAsWidthByHeight() {
        XCTAssertEqual(FrameSize(width: 402, height: 874).description, "402x874")
    }

    // MARK: GrayFrame

    func testGrayFrameExposesLuminanceByCoordinate() throws {
        let size = FrameSize(width: 3, height: 2)
        let frame = try GrayFrame(size: size, pixels: [0, 1, 2, 3, 4, 5])

        XCTAssertEqual(frame.luminance(x: 0, y: 0), 0)
        XCTAssertEqual(frame.luminance(x: 2, y: 1), 5)
        XCTAssertEqual(frame.width, 3)
        XCTAssertEqual(frame.height, 2)
    }

    func testGrayFrameReturnsNilOutsideItsBounds() throws {
        let frame = try GrayFrame(size: FrameSize(width: 2, height: 2), pixels: [1, 2, 3, 4])

        XCTAssertNil(frame.luminance(x: -1, y: 0))
        XCTAssertNil(frame.luminance(x: 0, y: -1))
        XCTAssertNil(frame.luminance(x: 2, y: 0))
        XCTAssertNil(frame.luminance(x: 0, y: 2))
    }

    func testGrayFrameRejectsAPixelCountThatDoesNotFillItsSize() {
        XCTAssertThrowsError(
            try GrayFrame(size: FrameSize(width: 2, height: 2), pixels: [1, 2, 3])
        ) {
            XCTAssertEqual($0 as? FrameError, .pixelCountMismatch(expected: 4, actual: 3))
        }
    }

    func testGrayFrameRejectsANonPositiveSize() {
        XCTAssertThrowsError(try GrayFrame(size: FrameSize(width: 0, height: 4), pixels: [])) {
            XCTAssertEqual($0 as? FrameError, .invalidTargetSize(width: 0, height: 4))
        }
    }

    // MARK: FrameError messages

    func testFrameErrorDescriptionsNameTheOperands() {
        let size = FrameSize(width: 40, height: 87)
        XCTAssertEqual(
            FrameError.invalidTargetSize(width: 0, height: 87).description,
            "invalid target size 0x87: both dimensions must be positive"
        )
        XCTAssertEqual(
            FrameError.grayscaleContextUnavailable(size).description,
            "could not create a 40x87 grayscale bitmap context"
        )
        XCTAssertEqual(
            FrameError.pixelDataUnavailable.description,
            "bitmap context exposed no pixel data"
        )
        XCTAssertEqual(
            FrameError.pixelCountMismatch(expected: 4, actual: 3).description,
            "frame needs 4 pixels, got 3"
        )
        XCTAssertEqual(
            FrameError.sizeMismatch(size, FrameSize(width: 2, height: 2)).description,
            "frame size mismatch: 40x87 vs 2x2"
        )
    }

    // MARK: StabilityVerdict

    func testVerdictKnowsWhetherItSettled() {
        XCTAssertTrue(StabilityVerdict.settled(afterMs: 180, polls: 3).isSettled)
        XCTAssertFalse(StabilityVerdict.timedOut(lastDiff: 3.2, polls: 5).isSettled)
    }

    func testTimeoutVerdictBeforeAnyPollReportsAZeroDiff() {
        XCTAssertEqual(
            StabilityEvaluator().timeoutVerdict,
            .timedOut(lastDiff: 0, polls: 0)
        )
    }

    // MARK: MotionTimeline edges

    func testTimelineWithoutAnIntervalReportsZeroFPS() {
        let simultaneous = MotionTimeline(
            samples: [TimelineSample(tMs: 90, diff: 1.0), TimelineSample(tMs: 90, diff: 0.2)]
        )

        XCTAssertEqual(simultaneous.fps, 0, accuracy: 1e-9)
    }

    // MARK: ScreenshotBudgetError messages

    func testScreenshotBudgetRejectsAZeroTargetWidth() {
        XCTAssertThrowsError(
            try ScreenshotBudget.plan(
                sourcePixelSize: FrameSize(width: 1_206, height: 2_622),
                pointSize: FrameSize(width: 402, height: 874),
                targetWidth: 0
            )
        ) {
            XCTAssertEqual($0 as? ScreenshotBudgetError, .invalidTargetWidth(0))
        }
    }

    func testScreenshotBudgetErrorDescriptionsNameTheOperands() {
        XCTAssertEqual(
            ScreenshotBudgetError.invalidSourceSize(FrameSize(width: 0, height: 2)).description,
            "invalid source pixel size 0x2"
        )
        XCTAssertEqual(
            ScreenshotBudgetError.invalidPointSize(FrameSize(width: 402, height: 0)).description,
            "invalid logical point size 402x0"
        )
        XCTAssertEqual(
            ScreenshotBudgetError.invalidTargetWidth(0).description,
            "invalid target width 0: must be positive"
        )
        XCTAssertEqual(
            ScreenshotBudgetError.targetWidthExceedsSource(requested: 1_207, sourceWidth: 1_206)
                .description,
            "target width 1207 exceeds the source width 1206"
        )
    }
}
