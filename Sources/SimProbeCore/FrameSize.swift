/// The dimensions of a `GrayFrame`, in pixels.
///
/// A separate type rather than a tuple so that a size mismatch can be reported with both
/// operands and so that call sites read `to: FrameSize(width: 40, height: 87)` rather than
/// passing two bare integers in an order the reader has to remember.
public struct FrameSize: Equatable, Hashable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// Number of pixels a frame of this size holds.
    public var pixelCount: Int { width * height }

    /// Whether both dimensions are usable as bitmap dimensions.
    public var isPositive: Bool { width > 0 && height > 0 }
}

extension FrameSize: CustomStringConvertible {
    public var description: String { "\(width)x\(height)" }
}
