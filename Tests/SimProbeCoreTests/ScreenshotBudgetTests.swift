import SimProbeCore
import XCTest

final class ScreenshotBudgetTests: XCTestCase {

    private let sourcePixels = FrameSize(width: 1_206, height: 2_622)
    private let points = FrameSize(width: 402, height: 874)

    func testDerivesPointScaleFromPixelAndPointSize() throws {
        let plan = try ScreenshotBudget.plan(sourcePixelSize: sourcePixels, pointSize: points)

        XCTAssertEqual(plan.scale, 3.0, accuracy: 1e-9)
    }

    func testEstimatesVisionTokensAsWidthTimesHeightOverSevenFifty() throws {
        let plan = try ScreenshotBudget.plan(sourcePixelSize: sourcePixels, pointSize: points)

        XCTAssertEqual(plan.estimatedVisionTokens, (402 * 874) / 750)
        XCTAssertEqual(plan.estimatedVisionTokens, 468)
    }

    func testDefaultTargetWidthEqualsLogicalPointWidth() throws {
        let plan = try ScreenshotBudget.plan(sourcePixelSize: sourcePixels, pointSize: points)

        XCTAssertEqual(plan.outputSize, points)
        XCTAssertEqual(plan.outputSize.width, points.width)
    }

    func testExplicitTargetWidthPreservesAspectRatio() throws {
        let plan = try ScreenshotBudget.plan(
            sourcePixelSize: sourcePixels,
            pointSize: points,
            targetWidth: 201
        )

        XCTAssertEqual(plan.outputSize, FrameSize(width: 201, height: 437))
        XCTAssertEqual(plan.scale, 3.0, accuracy: 1e-9)
    }

    func testRejectsTargetWidthLargerThanSourcePixelWidth() {
        XCTAssertThrowsError(
            try ScreenshotBudget.plan(
                sourcePixelSize: sourcePixels,
                pointSize: points,
                targetWidth: 1_207
            )
        ) {
            XCTAssertEqual(
                $0 as? ScreenshotBudgetError,
                .targetWidthExceedsSource(requested: 1_207, sourceWidth: 1_206)
            )
        }
    }

    func testRejectsNonPositiveSizes() {
        XCTAssertThrowsError(
            try ScreenshotBudget.plan(
                sourcePixelSize: FrameSize(width: 0, height: 2_622),
                pointSize: points
            )
        ) {
            XCTAssertEqual(
                $0 as? ScreenshotBudgetError,
                .invalidSourceSize(FrameSize(width: 0, height: 2_622))
            )
        }
        XCTAssertThrowsError(
            try ScreenshotBudget.plan(
                sourcePixelSize: sourcePixels,
                pointSize: FrameSize(width: 402, height: 0)
            )
        ) {
            XCTAssertEqual(
                $0 as? ScreenshotBudgetError,
                .invalidPointSize(FrameSize(width: 402, height: 0))
            )
        }
    }

    func testScaleIsNeverHardcodedForANonRetinaSource() throws {
        let plan = try ScreenshotBudget.plan(
            sourcePixelSize: FrameSize(width: 804, height: 1_748),
            pointSize: points
        )

        XCTAssertEqual(plan.scale, 2.0, accuracy: 1e-9)
    }
}
