import CoreGraphics
import XCTest

/// Grayscale fixtures built at run time. No image is ever committed: `*.png` is git-ignored,
/// and a binary fixture would be unreviewable anyway.
///
/// Frames are built at the thumbnail's own 40x87 so that `Thumbnail.downscale` is an identity
/// blit and a test can state the exact mean absolute difference it expects.
enum TestFrames {

    static let thumbnailWidth = 40
    static let thumbnailHeight = 87

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

    static func uniform(width: Int, height: Int, luminance: UInt8) throws -> CGImage {
        try gray(width: width, height: height) { _, _ in luminance }
    }

    /// A thumbnail-sized frame of `base` luminance, with `spots` pixels raised by one.
    ///
    /// The mean absolute difference against `thumbnail(base:)` is therefore exactly
    /// `spots / (40 * 87)`, which is how a test can assert a printed `0.01`.
    static func thumbnail(base: UInt8, raisedPixels spots: Int = 0) throws -> CGImage {
        try gray(width: thumbnailWidth, height: thumbnailHeight) { x, y in
            y * thumbnailWidth + x < spots ? base + 1 : base
        }
    }
}
