/// Failures raised while building or comparing frames.
///
/// Every case is explicit and carries the operands needed to explain it. Nothing in this
/// module returns a plausible-looking number in place of an error: a diff between two frames
/// of different sizes has no meaning, so it throws rather than silently comparing prefixes.
public enum FrameError: Error, Equatable, Sendable {
    /// A target thumbnail size with a non-positive dimension was requested.
    case invalidTargetSize(width: Int, height: Int)

    /// CoreGraphics refused to create the 8-bit grayscale bitmap context used for downscaling.
    case grayscaleContextUnavailable(FrameSize)

    /// The bitmap context produced no readable pixel buffer.
    case pixelDataUnavailable

    /// A `GrayFrame` was constructed with a pixel count that does not match its size.
    case pixelCountMismatch(expected: Int, actual: Int)

    /// Two frames of different sizes were compared.
    case sizeMismatch(FrameSize, FrameSize)
}

extension FrameError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidTargetSize(let width, let height):
            return "invalid target size \(width)x\(height): both dimensions must be positive"
        case .grayscaleContextUnavailable(let size):
            return "could not create a \(size) grayscale bitmap context"
        case .pixelDataUnavailable:
            return "bitmap context exposed no pixel data"
        case .pixelCountMismatch(let expected, let actual):
            return "frame needs \(expected) pixels, got \(actual)"
        case .sizeMismatch(let lhs, let rhs):
            return "frame size mismatch: \(lhs) vs \(rhs)"
        }
    }
}
