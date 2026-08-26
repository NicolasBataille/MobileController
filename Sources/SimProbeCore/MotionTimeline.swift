import Foundation

/// One measurement in a motion capture: a timestamp and the diff observed at it.
///
/// Timestamps are the ones the capture actually happened at, never the ones the caller asked
/// for. `simctl` screenshots cost roughly 200 ms each, so a requested 60 ms interval yields a
/// real cadence closer to 5 fps; reporting the request instead of the measurement would make
/// every timeline a fiction.
public struct TimelineSample: Equatable, Sendable, Codable {
    public let tMs: Int
    public let diff: Double

    public init(tMs: Int, diff: Double) {
        self.tMs = tMs
        self.diff = diff
    }
}

/// A sequence of diffs over time, rendered compactly for an agent to read.
///
/// The whole point of `motion` is to answer "did it animate, and when did it stop?" without
/// putting a single image byte on stdout. Both output forms here are pure text.
public struct MotionTimeline: Equatable, Sendable {

    public let samples: [TimelineSample]
    public let tolerance: Double

    /// The frame-writing cap that was hit, or `nil` when none was. Sampling is never capped:
    /// only the optional PNGs a caller asked to keep are, so a capped timeline still answers
    /// the question the verb was asked. Reported so a caller does not read a short directory
    /// as a short run.
    public let framesCappedAt: Int?

    public init(
        samples: [TimelineSample],
        tolerance: Double = FrameDiff.defaultTolerance,
        framesCappedAt: Int? = nil
    ) {
        self.samples = samples
        self.tolerance = tolerance
        self.framesCappedAt = framesCappedAt
    }

    /// Whether any sample exceeded tolerance, i.e. whether the screen moved at all.
    ///
    /// A caller reading `settledAtMs` alone cannot tell "moved, then stopped at t" from
    /// "never moved, so it was already settled at t"; this flag makes that distinction
    /// without a second capture.
    public var hadMotion: Bool {
        samples.contains { $0.diff > tolerance }
    }

    /// Timestamp of the moment motion ended: the first sample within tolerance that comes
    /// *after* the last sample exceeding it. `nil` when the timeline ends still moving.
    ///
    /// Not the first quiet sample overall: a window that opens before the transition starts
    /// (a tap that takes 300 ms to produce anything) begins with quiet samples, and reporting
    /// one of those would date the settle point before the animation it is supposed to
    /// measure. A timeline with no motion at all settles at its first sample - see
    /// `hadMotion` to tell the two cases apart.
    public var settledAtMs: Int? {
        guard let lastMotion = samples.lastIndex(where: { $0.diff > tolerance }) else {
            return samples.first?.tMs
        }
        let firstQuiet = samples.index(after: lastMotion)
        guard firstQuiet < samples.endIndex else { return nil }
        return samples[firstQuiet].tMs
    }

    /// Measured sampling rate, derived from the first and last actual timestamps.
    ///
    /// Zero for fewer than two samples, or when every sample shares a timestamp: a cadence
    /// needs an interval to be measured over.
    public var fps: Double {
        guard let first = samples.first, let last = samples.last, samples.count > 1 else {
            return 0
        }
        let spanMs = last.tMs - first.tMs
        guard spanMs > 0 else { return 0 }
        return Double(samples.count - 1) * 1_000 / Double(spanMs)
    }

    /// The compact human-readable form, for example
    /// `t=0 11.00, 210 3.20, 415 0.40, 620 0.01  ->  settled@415ms (4 samples, 4.8 fps)`.
    public func formatted() -> String {
        guard !samples.isEmpty else { return "no samples" }
        let parts = samples.map { String(format: "%d %.2f", $0.tMs, $0.diff) }
        let body = parts.joined(separator: ", ")
        let outcome = settledAtMs.map { "settled@\($0)ms" } ?? "not settled"
        let noun = samples.count == 1 ? "sample" : "samples"
        let summary = String(format: "(%d \(noun), %.1f fps)", samples.count, fps)
        let motion = hadMotion ? "" : " (no motion)"
        let capped = framesCappedAt.map { " (frames capped at \($0))" } ?? ""
        return "t=\(body)  ->  \(outcome) \(summary)\(motion)\(capped)"
    }

    /// The machine-readable form, with keys sorted so the output is byte-stable.
    ///
    /// `settledAtMs` is always present, `null` when the screen never settled, so a caller
    /// parsing the JSON never has to distinguish "absent" from "did not settle". `hadMotion`
    /// tells a settled timeline that moved from one that never did, and `framesCapped` says
    /// whether `--keep-frames` stopped writing before the run ended.
    public func jsonEncoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Payload(timeline: self))
    }

    private struct Payload: Encodable {
        let settledAtMs: Int?
        let hadMotion: Bool
        let samples: [TimelineSample]
        let tol: Double
        let fps: Double
        let framesCapped: Bool

        init(timeline: MotionTimeline) {
            settledAtMs = timeline.settledAtMs
            hadMotion = timeline.hadMotion
            samples = timeline.samples
            tol = timeline.tolerance
            fps = (timeline.fps * 10).rounded() / 10
            framesCapped = timeline.framesCappedAt != nil
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            // encode, not encodeIfPresent: the key must survive a nil settle point.
            try container.encode(settledAtMs, forKey: .settledAtMs)
            try container.encode(hadMotion, forKey: .hadMotion)
            try container.encode(samples, forKey: .samples)
            try container.encode(tol, forKey: .tol)
            try container.encode(fps, forKey: .fps)
            // Always present, like the keys above: a caller must be able to tell "not capped"
            // from "this build did not know about capping" without inspecting the directory.
            try container.encode(framesCapped, forKey: .framesCapped)
        }

        enum CodingKeys: String, CodingKey {
            case settledAtMs, hadMotion, samples, tol, fps, framesCapped
        }
    }
}
