import ArgumentParser
import SimProbeCore

struct WaitStableCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "wait-stable",
        abstract: "Poll a simulator's screen until it stops changing.",
        discussion: """
            Captures thumbnails until --quiet-polls consecutive comparisons fall within \
            --tol, then prints when that happened and how many comparisons it took. Exits 3 \
            if the screen was still moving when --timeout elapsed.

            Wall time is capture-bound: each poll costs one screenshot (0.2-1.1s), so the \
            floor is (--quiet-polls + 1) captures. Lower --quiet-polls to 2 when a lone quiet \
            frame mid-animation is not a risk, e.g. right after a screen is known to be idle.

            Durations accept a bare number of milliseconds, or an ms/s suffix: 250, 60ms, 1.5s.

            --udid accepts a UDID or a device name; omit it and the single booted \
            simulator is used, or exit 2 lists the candidates when that is ambiguous.
            """
    )

    @Option(help: "UDID or name of the simulator to watch. Defaults to the booted one.")
    var udid: String?

    @Option(help: "Mean absolute luminance difference below which a screen counts as quiet.")
    var tol: Double = FrameDiff.defaultTolerance

    @Option(
        help: """
            Consecutive quiet comparisons required before the screen counts as settled. \
            Three rejects the single quiet frame a crossfade produces mid-animation; two \
            costs one capture less. Minimum 1.
            """
    )
    var quietPolls: Int = StabilityEvaluator.defaultQuietPolls

    @Option(
        help: """
            How long to keep polling before giving up. Six seconds because a loaded host can \
            spend over a second per capture, and a 4s budget expired mid-watch on screens \
            that had never moved.
            """
    )
    var timeout: String = "6s"

    @Option(help: "Gap between captures; the real cadence is capture-bound.")
    var interval: String = "60ms"

    @Flag(help: "Emit one line of JSON instead of the human-readable form.")
    var json = false

    func run() throws {
        try CommandExit.reporting(json: json) { output in
            let session = try ProbeSession.live()
            let options = WaitStableOptions(
                udid: try session.udid(for: udid),
                tolerance: tol,
                quietPollsRequired: try WaitStableOptions.validatedQuietPolls(quietPolls),
                timeoutMs: try Milliseconds.parse(timeout),
                intervalMs: try Milliseconds.parse(interval),
                json: json
            )
            return try WaitStableRunner(options: options).run(
                in: session.environment(output: output))
        }
    }
}
