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
            """
    )

    @Option(help: "UDID of the simulator to watch.")
    var udid: String

    @Option(help: "Mean absolute luminance difference below which a screen counts as quiet.")
    var tol: Double = FrameDiff.defaultTolerance

    @Option(help: "How long to keep polling before giving up.")
    var timeout: String = "4s"

    @Option(help: "Gap between captures; the real cadence is capture-bound.")
    var interval: String = "60ms"

    @Flag(help: "Emit one line of JSON instead of the human-readable form.")
    var json = false

    func run() throws {
        let output = StandardOutput()
        do {
            let options = WaitStableOptions(
                udid: udid,
                tolerance: tol,
                timeoutMs: try Milliseconds.parse(timeout),
                intervalMs: try Milliseconds.parse(interval),
                json: json
            )
            let environment = ProbeEnvironment.live(simctl: try Simctl.locate(), output: output)
            try CommandExit.finish(WaitStableRunner(options: options).run(in: environment))
        } catch let error as ProbeError {
            ErrorReporter.report(error, json: json, to: output)
            throw ExitCode(error.exitCode)
        }
    }
}
