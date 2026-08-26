/// Compares two thumbnails and answers "how much did the screen change?" as one number.
///
/// The measure is the mean absolute difference of the luminance channel, on the same 0-255
/// scale as the pixels themselves. Exact equality is deliberately not used: a screen carrying
/// any perpetual micro-animation never produces two identical frames, so a hash comparison
/// polls forever and answers nothing.
public enum FrameDiff {

    /// The largest value `meanAbsoluteDifference` can return: a fully black frame against a
    /// fully white one.
    public static let maximumDifference = 255.0

    /// Default threshold separating "the screen is settled" from "the screen is moving".
    ///
    /// Measured on a real device screen: an idle screen carrying a perpetual micro-animation
    /// scores **0.00-0.03**, while a real screen transition scores **11.01**. A threshold of
    /// 0.5 sits between the two bands with roughly 17x headroom below and 22x above, so it
    /// separates them by about 350x overall without needing per-app tuning. Callers that need
    /// a different band pass their own tolerance; `simprobe motion` prints the raw timeline so
    /// a user can pick one from their own screen.
    public static let defaultTolerance = 0.5

    /// Mean absolute luminance difference between two frames, in the 0-255 pixel scale.
    ///
    /// - Throws: `FrameError.sizeMismatch` when the frames are not the same size. Comparing
    ///   frames of different sizes has no meaning, so it is an error rather than a number.
    public static func meanAbsoluteDifference(_ lhs: GrayFrame, _ rhs: GrayFrame) throws -> Double {
        guard lhs.size == rhs.size else {
            throw FrameError.sizeMismatch(lhs.size, rhs.size)
        }
        var total = 0
        for index in lhs.pixels.indices {
            total += abs(Int(lhs.pixels[index]) - Int(rhs.pixels[index]))
        }
        return Double(total) / Double(lhs.size.pixelCount)
    }

    /// Whether two frames differ by more than `tolerance`.
    ///
    /// - Throws: `FrameError.sizeMismatch`, as `meanAbsoluteDifference` does.
    public static func exceedsTolerance(
        _ lhs: GrayFrame,
        _ rhs: GrayFrame,
        tolerance: Double = defaultTolerance
    ) throws -> Bool {
        try meanAbsoluteDifference(lhs, rhs) > tolerance
    }
}
