/// Pure state machine deciding when a screen has stopped moving.
///
/// The poll loop - capture, sleep, capture again - lives in the executable. This type only
/// folds the resulting measurements, so `wait-stable`'s "settled after 180ms (3 polls)" can be
/// asserted deterministically with no simulator, no clock and no disk.
///
/// Every transition returns a new value; nothing here mutates.
public struct StabilityEvaluator: Equatable, Sendable {

    /// Consecutive quiet comparisons required before a screen counts as settled.
    ///
    /// Three, because a single quiet frame pair is routinely produced mid-transition: an
    /// animation that crosses its own start value, or a crossfade at the moment two layers
    /// balance, both yield one near-zero diff while the screen is still moving.
    public static let defaultQuietPolls = 3

    /// Default watch budget, matching the documented `--timeout 6s`.
    ///
    /// Six, not four: on a loaded host a single `simctl` screenshot can cost more than a
    /// second, so a four-second budget expired mid-watch and reported a screen that had never
    /// moved as still moving. The budget only bounds the failure case - a settled screen
    /// still returns as soon as the quiet run completes.
    public static let defaultTimeoutMs = 6_000

    // MARK: Configuration

    public let tolerance: Double
    public let quietPollsRequired: Int
    public let timeoutMs: Int
    public let startedAtMs: Int

    // MARK: Accumulated state

    /// Number of frame comparisons made. The baseline frame is not a comparison.
    public let polls: Int

    /// Length of the current run of consecutive quiet comparisons.
    public let quietPolls: Int

    /// The most recent mean absolute difference, `nil` before the first comparison.
    public let lastDiff: Double?

    /// Milliseconds between `startedAtMs` and the most recent observation.
    public let elapsedMs: Int

    private let baseline: GrayFrame?

    public init(
        tolerance: Double = FrameDiff.defaultTolerance,
        quietPollsRequired: Int = StabilityEvaluator.defaultQuietPolls,
        timeoutMs: Int = StabilityEvaluator.defaultTimeoutMs,
        startedAtMs: Int = 0
    ) {
        self.init(
            tolerance: tolerance,
            quietPollsRequired: quietPollsRequired,
            timeoutMs: timeoutMs,
            startedAtMs: startedAtMs,
            polls: 0,
            quietPolls: 0,
            lastDiff: nil,
            elapsedMs: 0,
            baseline: nil
        )
    }

    private init(
        tolerance: Double,
        quietPollsRequired: Int,
        timeoutMs: Int,
        startedAtMs: Int,
        polls: Int,
        quietPolls: Int,
        lastDiff: Double?,
        elapsedMs: Int,
        baseline: GrayFrame?
    ) {
        self.tolerance = tolerance
        self.quietPollsRequired = quietPollsRequired
        self.timeoutMs = timeoutMs
        self.startedAtMs = startedAtMs
        self.polls = polls
        self.quietPolls = quietPolls
        self.lastDiff = lastDiff
        self.elapsedMs = elapsedMs
        self.baseline = baseline
    }

    // MARK: Folding

    /// Records one comparison and returns the resulting evaluator.
    public func observing(diff: Double, atMs ms: Int) -> StabilityEvaluator {
        StabilityEvaluator(
            tolerance: tolerance,
            quietPollsRequired: quietPollsRequired,
            timeoutMs: timeoutMs,
            startedAtMs: startedAtMs,
            polls: polls + 1,
            quietPolls: diff > tolerance ? 0 : quietPolls + 1,
            lastDiff: diff,
            elapsedMs: ms - startedAtMs,
            baseline: baseline
        )
    }

    /// Records one captured frame, comparing it against the previously observed one.
    ///
    /// The first frame is only a baseline: it establishes what the next frame is compared
    /// against and never produces a verdict, because a single frame carries no movement.
    ///
    /// - Throws: `FrameError.sizeMismatch` when the frame size changed mid-watch.
    public func observing(_ frame: GrayFrame, atMs ms: Int) throws -> StabilityEvaluator {
        guard let baseline else {
            return withBaseline(frame, elapsedMs: ms - startedAtMs)
        }
        let diff = try FrameDiff.meanAbsoluteDifference(baseline, frame)
        return observing(diff: diff, atMs: ms).withBaseline(frame, elapsedMs: ms - startedAtMs)
    }

    private func withBaseline(_ frame: GrayFrame, elapsedMs: Int) -> StabilityEvaluator {
        StabilityEvaluator(
            tolerance: tolerance,
            quietPollsRequired: quietPollsRequired,
            timeoutMs: timeoutMs,
            startedAtMs: startedAtMs,
            polls: polls,
            quietPolls: quietPolls,
            lastDiff: lastDiff,
            elapsedMs: elapsedMs,
            baseline: frame
        )
    }

    // MARK: Verdict

    /// The verdict, or `nil` while the watch should keep polling.
    public var verdict: StabilityVerdict? {
        if quietPolls >= quietPollsRequired {
            return .settled(afterMs: elapsedMs, polls: polls)
        }
        if elapsedMs >= timeoutMs {
            return timeoutVerdict
        }
        return nil
    }

    /// The verdict to report when the caller's own clock passed the deadline without a further
    /// poll - a capture that took longer than the remaining budget, for instance.
    public var timeoutVerdict: StabilityVerdict {
        .timedOut(lastDiff: lastDiff ?? 0, polls: polls)
    }
}
