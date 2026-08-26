/// An immutable 8-bit grayscale image, small enough to compare cheaply.
///
/// This is the only image representation `SimProbeCore` works with. Screenshots are downscaled
/// to a thumbnail before anything is measured, which is what makes the stability signal cheap:
/// a 40x87 frame is 3,480 bytes, so a full poll cycle costs microseconds of arithmetic rather
/// than megabytes of pixel walking.
public struct GrayFrame: Equatable, Hashable, Sendable {
    public let size: FrameSize

    /// Row-major luminance values, `size.pixelCount` of them.
    public let pixels: [UInt8]

    public var width: Int { size.width }
    public var height: Int { size.height }

    /// - Throws: `FrameError.invalidTargetSize` for a non-positive size,
    ///   `FrameError.pixelCountMismatch` when `pixels` does not fill exactly that size.
    public init(size: FrameSize, pixels: [UInt8]) throws {
        guard size.isPositive else {
            throw FrameError.invalidTargetSize(width: size.width, height: size.height)
        }
        guard pixels.count == size.pixelCount else {
            throw FrameError.pixelCountMismatch(expected: size.pixelCount, actual: pixels.count)
        }
        self.size = size
        self.pixels = pixels
    }

    /// Luminance at a coordinate, or `nil` when the coordinate is outside the frame.
    public func luminance(x: Int, y: Int) -> UInt8? {
        guard x >= 0, y >= 0, x < size.width, y < size.height else { return nil }
        return pixels[y * size.width + x]
    }
}
