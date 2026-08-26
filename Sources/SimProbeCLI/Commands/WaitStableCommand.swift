import ArgumentParser
import SimProbeCore

struct WaitStableCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "wait-stable",
        abstract: "Poll a simulator's screen until it stops changing.",
        discussion: """
            Captures thumbnails until three consecutive comparisons fall within --tol, then \
            prints when that happened and how many comparisons it took. Exits 3 if the \
            screen was still moving when --timeout elapsed.

            Durations accept a bare number of milliseconds, or an ms/s suffix: 250, 60ms, 1.5s.

            --udid accepts a UDID or a device name; omit it and the single booted \
            simulator is used, or exit 2 lists the candidates when that is ambiguous.
            """
    )

    @Option(help: "UDID or name of the simulator to watch. Defaults to the booted one.")
    var udid: String?

    @Option(help: "Mean absolute luminance difference below which a screen counts as quiet.")
    var tol: Double = FrameDiff.defaultTolerance

    @Option(help: "How long to keep polling before giving up.")
    var timeout: String = "4s"

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
                timeoutMs: try Milliseconds.parse(timeout),
                intervalMs: try Milliseconds.parse(interval),
                json: json
            )
            return try WaitStableRunner(options: options).run(
                in: session.environment(output: output))
        }
    }
}
