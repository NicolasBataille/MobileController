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

    public init(samples: [TimelineSample], tolerance: Double = FrameDiff.defaultTolerance) {
        self.samples = samples
        self.tolerance = tolerance
    }

    /// Timestamp of the first sample that fell within tolerance, or `nil` if none did.
    public var settledAtMs: Int? {
        samples.first { $0.diff <= tolerance }?.tMs
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
        let summary = String(format: "(%d samples, %.1f fps)", samples.count, fps)
        return "t=\(body)  ->  \(outcome) \(summary)"
    }

    /// The machine-readable form, with keys sorted so the output is byte-stable.
    ///
    /// `settledAtMs` is always present, `null` when the screen never settled, so a caller
    /// parsing the JSON never has to distinguish "absent" from "did not settle".
    public func jsonEncoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Payload(timeline: self))
    }

    private struct Payload: Encodable {
        let settledAtMs: Int?
        let samples: [TimelineSample]
        let tol: Double
        let fps: Double

        init(timeline: MotionTimeline) {
            settledAtMs = timeline.settledAtMs
            samples = timeline.samples
            tol = timeline.tolerance
            fps = (timeline.fps * 10).rounded() / 10
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            // encode, not encodeIfPresent: the key must survive a nil settle point.
            try container.encode(settledAtMs, forKey: .settledAtMs)
            try container.encode(samples, forKey: .samples)
            try container.encode(tol, forKey: .tol)
            try container.encode(fps, forKey: .fps)
        }

        enum CodingKeys: String, CodingKey {
            case settledAtMs, samples, tol, fps
        }
    }
}
