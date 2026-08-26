/// The outcome of watching a screen for movement.
///
/// There are exactly two ways a stability watch ends, and both carry the evidence for the
/// answer: a settled screen reports when it settled and how many comparisons it took, a
/// timed-out one reports the diff it was still seeing when it gave up. Neither collapses to a
/// bare boolean, because "not stable" with no number attached is not actionable.
public enum StabilityVerdict: Equatable, Sendable {
    /// The screen was quiet for the required number of consecutive polls.
    ///
    /// - Parameters:
    ///   - afterMs: milliseconds between the start of the watch and the settling poll.
    ///   - polls: number of frame comparisons made.
    case settled(afterMs: Int, polls: Int)

    /// The screen was still moving when the timeout elapsed.
    ///
    /// - Parameters:
    ///   - lastDiff: the most recent mean absolute difference, on the 0-255 scale.
    ///   - polls: number of frame comparisons made.
    case timedOut(lastDiff: Double, polls: Int)

    public var isSettled: Bool {
        if case .settled = self { return true }
        return false
    }
}
