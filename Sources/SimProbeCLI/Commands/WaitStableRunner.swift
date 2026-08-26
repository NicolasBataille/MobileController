import Foundation
import SimProbeCore

/// What `wait-stable` was asked to do, separated from how it was asked.
public struct WaitStableOptions: Equatable, Sendable {

    /// Default gap between captures.
    ///
    /// 60 ms means "no artificial delay": one `simctl` screenshot costs on the order of
    /// 200 ms, so the real cadence is capture-bound and this value never dominates it.
    public static let defaultIntervalMs = 60

    public let udid: String
    public let tolerance: Double
    public let timeoutMs: Int
    public let intervalMs: Int
    public let json: Bool

    public init(
        udid: String,
        tolerance: Double = FrameDiff.defaultTolerance,
        timeoutMs: Int = StabilityEvaluator.defaultTimeoutMs,
        intervalMs: Int = WaitStableOptions.defaultIntervalMs,
        json: Bool = false
    ) {
        self.udid = udid
        self.tolerance = tolerance
        self.timeoutMs = timeoutMs
        self.intervalMs = intervalMs
        self.json = json
    }
}

/// Polls a screen until it stops moving, or until the budget runs out.
///
/// The decision itself belongs to `SimProbeCore.StabilityEvaluator`; all this adds is the
/// capture-sleep-capture loop and the two output forms.
public struct WaitStableRunner {

    private let options: WaitStableOptions

    public init(options: WaitStableOptions) {
        self.options = options
    }

    /// - Returns: 0 when the screen settled, 3 when the timeout elapsed first.
    public func run(in environment: ProbeEnvironment) throws -> Int32 {
        let watch = try observe(in: environment)
        environment.output.writeLine(
            options.json ? try jsonLine(watch) : humanLine(watch)
        )
        return watch.settled ? 0 : 3
    }

    private func observe(in environment: ProbeEnvironment) throws -> Watch {
        let startedAtMs = environment.clock.nowMs
        var evaluator = StabilityEvaluator(
            tolerance: options.tolerance,
            timeoutMs: options.timeoutMs,
            startedAtMs: startedAtMs
        )
        while true {
            let image = try environment.capture.capture(udid: options.udid)
            let frame = try Frames.thumbnail(of: image)
            evaluator = try Frames.observe(evaluator, frame, atMs: environment.clock.nowMs)
            if let verdict = evaluator.verdict {
                return Watch(evaluator: evaluator, settled: verdict.isSettled)
            }
            let remainingMs = options.timeoutMs - (environment.clock.nowMs - startedAtMs)
            environment.clock.sleep(ms: min(options.intervalMs, max(remainingMs, 0)))
        }
    }

    private func humanLine(_ watch: Watch) -> String {
        let verdict = watch.settled ? "stable" : "not stable"
        let polls = watch.evaluator.polls == 1 ? "poll" : "polls"
        return verdict
            + String(
                format: " after %dms (%d \(polls), last diff %.2f, tol %.2f)",
                watch.evaluator.elapsedMs,
                watch.evaluator.polls,
                watch.evaluator.lastDiff ?? 0,
                options.tolerance
            )
    }

    private func jsonLine(_ watch: Watch) throws -> String {
        try JSONLine.encode(
            Report(
                stable: watch.settled,
                elapsedMs: watch.evaluator.elapsedMs,
                polls: watch.evaluator.polls,
                lastDiff: watch.evaluator.lastDiff ?? 0,
                tol: options.tolerance,
                udid: options.udid
            )
        )
    }

    private struct Watch {
        let evaluator: StabilityEvaluator
        let settled: Bool
    }

    private struct Report: Encodable {
        let stable: Bool
        let elapsedMs: Int
        let polls: Int
        let lastDiff: Double
        let tol: Double
        let udid: String
    }
}
