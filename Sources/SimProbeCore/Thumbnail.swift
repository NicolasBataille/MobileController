import CoreGraphics

/// Reduces a screenshot to the small grayscale frame every measurement is made on.
///
/// Downscaling is not an optimisation detail, it is the measurement. Comparing full-resolution
/// framebuffers makes every frame differ (compression noise, a blinking caret, a one-pixel
/// shadow), which is why exact-hash equality never converges on a real screen. At 40x87 those
/// disturbances average out and a genuine screen transition still stands out by two orders of
/// magnitude.
public enum Thumbnail {

    /// The measured working size: 40x87 grayscale.
    ///
    /// Chosen against a 402x874-point iPhone screen, so it preserves the aspect ratio at
    /// roughly 1/10 scale. At this size an idle screen carrying a perpetual micro-animation
    /// scores 0.00-0.03 while a real screen transition scores about 11.
    public static let defaultSize = FrameSize(width: 40, height: 87)

    /// Renders `image` into an 8-bit grayscale bitmap of `size` and returns its pixels.
    ///
    /// - Parameters:
    ///   - image: any `CGImage`; colour images are converted to luminance by CoreGraphics.
    ///   - size: the target thumbnail size, `defaultSize` unless overridden.
    /// - Throws: `FrameError.invalidTargetSize`, `FrameError.grayscaleContextUnavailable`,
    ///   `FrameError.pixelDataUnavailable`.
    public static func downscale(
        _ image: CGImage,
        to size: FrameSize = defaultSize
    ) throws -> GrayFrame {
        guard size.isPositive else {
            throw FrameError.invalidTargetSize(width: size.width, height: size.height)
        }
        let context = try makeGrayContext(size: size)
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: size.width, height: size.height)
        )
        return try GrayFrame(size: size, pixels: readPixels(from: context, size: size))
    }

    private static func makeGrayContext(size: FrameSize) throws -> CGContext {
        guard
            let context = CGContext(
                data: nil,
                width: size.width,
                height: size.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        else {
            throw FrameError.grayscaleContextUnavailable(size)
        }
        return context
    }

    /// Copies the context's pixels row by row.
    ///
    /// `bytesPerRow` is chosen by CoreGraphics and is usually padded past `width`, so the rows
    /// cannot be read as one contiguous run.
    private static func readPixels(from context: CGContext, size: FrameSize) throws -> [UInt8] {
        guard let base = context.data else { throw FrameError.pixelDataUnavailable }
        let rowBytes = context.bytesPerRow
        let buffer = base.bindMemory(to: UInt8.self, capacity: rowBytes * size.height)
        var pixels = [UInt8]()
        pixels.reserveCapacity(size.pixelCount)
        for y in 0..<size.height {
            let row = y * rowBytes
            for x in 0..<size.width {
                pixels.append(buffer[row + x])
            }
        }
        return pixels
    }
}
