import CoreGraphics
import SimProbeCore
import XCTest

final class FrameDiffTests: XCTestCase {

    private let size = Thumbnail.defaultSize

    func testIdenticalFramesDiffZero() throws {
        let frame = try uniformFrame(luminance: 143)

        XCTAssertEqual(try FrameDiff.meanAbsoluteDifference(frame, frame), 0, accuracy: 1e-9)
    }

    func testBlackVsWhiteFramesDiffIsMaximum() throws {
        let black = try uniformFrame(luminance: 0)
        let white = try uniformFrame(luminance: 255)

        let diff = try FrameDiff.meanAbsoluteDifference(black, white)

        XCTAssertEqual(diff, 255, accuracy: 1e-9)
        XCTAssertEqual(diff, FrameDiff.maximumDifference, accuracy: 1e-9)
    }

    func testMismatchedSizesThrowSizeMismatch() throws {
        let tiny = FrameSize(width: 4, height: 4)
        let small = try GrayFrame(size: tiny, pixels: [UInt8](repeating: 0, count: tiny.pixelCount))
        let large = try uniformFrame(luminance: 0)

        XCTAssertThrowsError(try FrameDiff.meanAbsoluteDifference(small, large)) {
            XCTAssertEqual($0 as? FrameError, .sizeMismatch(small.size, large.size))
        }
    }

    /// A caret blinking in a handful of thumbnail pixels: the measured idle band is 0.00-0.03.
    func testSmallPerturbationStaysUnderDefaultTolerance() throws {
        let base = try uniformFrame(luminance: 128)
        var perturbed = base.pixels
        for index in 0..<4 { perturbed[index * 97] = 153 }
        let after = try GrayFrame(size: size, pixels: perturbed)

        let diff = try FrameDiff.meanAbsoluteDifference(base, after)

        XCTAssertLessThanOrEqual(diff, 0.03)
        XCTAssertLessThan(diff, FrameDiff.defaultTolerance)
    }

    /// A band of content sliding across the screen, downscaled through the real path.
    func testScreenTransitionMagnitudeExceedsTolerance() throws {
        let before = try transitionFrame(bandOriginX: 40)
        let after = try transitionFrame(bandOriginX: 160)

        let diff = try FrameDiff.meanAbsoluteDifference(before, after)

        XCTAssertGreaterThanOrEqual(diff, 5)
        XCTAssertGreaterThan(diff, FrameDiff.defaultTolerance)
    }

    func testDefaultToleranceIsANamedConstantBetweenTheMeasuredBands() {
        XCTAssertEqual(FrameDiff.defaultTolerance, 0.5, accuracy: 1e-9)
        XCTAssertGreaterThan(FrameDiff.defaultTolerance, 0.03)
        XCTAssertLessThan(FrameDiff.defaultTolerance, 11.01)
    }

    func testExceedsToleranceUsesTheGivenThreshold() throws {
        let base = try uniformFrame(luminance: 100)
        let shifted = try uniformFrame(luminance: 101)

        XCTAssertTrue(try FrameDiff.exceedsTolerance(base, shifted, tolerance: 0.5))
        XCTAssertFalse(try FrameDiff.exceedsTolerance(base, shifted, tolerance: 2))
    }

    private func uniformFrame(luminance: UInt8) throws -> GrayFrame {
        try GrayFrame(size: size, pixels: [UInt8](repeating: luminance, count: size.pixelCount))
    }

    private func transitionFrame(bandOriginX: Int) throws -> GrayFrame {
        let image = try TestImages.gray(width: 402, height: 874) { x, _ in
            (bandOriginX..<(bandOriginX + 40)).contains(x) ? 240 : 130
        }
        return try Thumbnail.downscale(image, to: size)
    }
}
