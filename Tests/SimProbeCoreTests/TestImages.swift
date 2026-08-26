import CoreGraphics
import XCTest

/// Fixtures are generated at run time with CoreGraphics. No image is ever committed:
/// `*.png` and `*.jpg` are git-ignored, and a binary fixture would be unreviewable anyway.
enum TestImages {

    /// Builds an 8-bit grayscale `CGImage` whose pixel at (x, y) is `luminance(x, y)`.
    static func gray(
        width: Int,
        height: Int,
        luminance: (Int, Int) -> UInt8
    ) throws -> CGImage {
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ),
            "could not create a grayscale bitmap context"
        )
        let base = try XCTUnwrap(context.data, "grayscale context exposed no pixel buffer")
        let rowBytes = context.bytesPerRow
        let buffer = base.bindMemory(to: UInt8.self, capacity: rowBytes * height)
        for y in 0..<height {
            for x in 0..<width {
                buffer[y * rowBytes + x] = luminance(x, y)
            }
        }
        return try XCTUnwrap(context.makeImage(), "grayscale context produced no image")
    }

    /// A single-luminance image.
    static func uniform(width: Int, height: Int, luminance: UInt8) throws -> CGImage {
        try gray(width: width, height: height) { _, _ in luminance }
    }

    /// Dark on the top half, bright on the bottom half, in row order: row 0 is the dark one.
    static func splitVertically(
        width: Int,
        height: Int,
        top: UInt8,
        bottom: UInt8
    ) throws -> CGImage {
        try gray(width: width, height: height) { _, y in y < height / 2 ? top : bottom }
    }

    /// Dark on the left half, bright on the right half.
    static func splitHorizontally(
        width: Int,
        height: Int,
        left: UInt8,
        right: UInt8
    ) throws -> CGImage {
        try gray(width: width, height: height) { x, _ in x < width / 2 ? left : right }
    }
}
