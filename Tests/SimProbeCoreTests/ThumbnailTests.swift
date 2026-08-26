import CoreGraphics
import SimProbeCore
import XCTest

final class ThumbnailTests: XCTestCase {

    func testDownscaleProducesRequestedDimensions() throws {
        let source = try TestImages.uniform(width: 402, height: 874, luminance: 90)

        let frame = try Thumbnail.downscale(source, to: FrameSize(width: 40, height: 87))

        XCTAssertEqual(frame.size, FrameSize(width: 40, height: 87))
        XCTAssertEqual(frame.pixels.count, 40 * 87)
    }

    func testDownscaleOfUniformImageIsUniform() throws {
        let source = try TestImages.uniform(width: 300, height: 600, luminance: 137)

        let frame = try Thumbnail.downscale(source, to: FrameSize(width: 40, height: 87))

        XCTAssertEqual(Set(frame.pixels), [137])
    }

    func testDownscalePreservesRelativeBrightnessOrdering() throws {
        let source = try TestImages.splitHorizontally(
            width: 400,
            height: 800,
            left: 20,
            right: 230
        )

        let frame = try Thumbnail.downscale(source, to: FrameSize(width: 40, height: 87))

        let leftMean = meanOfColumns(frame, 0..<18)
        let rightMean = meanOfColumns(frame, 22..<40)
        XCTAssertLessThan(leftMean, 60)
        XCTAssertGreaterThan(rightMean, 190)
        XCTAssertLessThan(leftMean, rightMean)
    }

    func testDownscaleIsDeterministicForSameInput() throws {
        let source = try TestImages.gray(width: 402, height: 874) { x, y in
            UInt8((x &* 7 &+ y &* 13) % 256)
        }

        let first = try Thumbnail.downscale(source, to: Thumbnail.defaultSize)
        let second = try Thumbnail.downscale(source, to: Thumbnail.defaultSize)

        XCTAssertEqual(first, second)
    }

    func testDefaultThumbnailSizeIsFortyByEightySeven() {
        XCTAssertEqual(Thumbnail.defaultSize, FrameSize(width: 40, height: 87))
    }

    func testDownscaleRejectsNonPositiveTargetSize() throws {
        let source = try TestImages.uniform(width: 100, height: 100, luminance: 10)

        XCTAssertThrowsError(try Thumbnail.downscale(source, to: FrameSize(width: 0, height: 87))) {
            XCTAssertEqual($0 as? FrameError, .invalidTargetSize(width: 0, height: 87))
        }
    }

    private func meanOfColumns(_ frame: GrayFrame, _ columns: Range<Int>) -> Double {
        var total = 0
        var count = 0
        for y in 0..<frame.size.height {
            for x in columns {
                total += Int(frame.pixels[y * frame.size.width + x])
                count += 1
            }
        }
        return count == 0 ? 0 : Double(total) / Double(count)
    }
}
