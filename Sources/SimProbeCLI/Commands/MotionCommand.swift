import ArgumentParser
import Foundation
import SimProbeCore

struct MotionCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "motion",
        abstract: "Report how much a simulator's screen changed over a window of time.",
        discussion: """
            Prints a diff timeline and the point at which the screen settled, with zero image \
            bytes on stdout. The first capture is a baseline, so the window starts once there \
            is something to compare against, and every timestamp is a measured one: a `simctl` \
            screenshot costs roughly 200 ms, which caps the real cadence near 5 fps.

            The duration accepts a bare number of milliseconds, or an ms/s suffix: 600, 1.5s.
            """
    )

    @Argument(help: "How long to watch for.")
    var duration: String

    @Option(help: "UDID of the simulator to watch.")
    var udid: String

    @Option(help: "Mean absolute luminance difference below which a screen counts as quiet.")
    var tol: Double = FrameDiff.defaultTolerance

    @Option(help: "Directory to write one PNG per sample into. Nothing is written without it.")
    var keepFrames: String?

    @Flag(help: "Emit one line of JSON instead of the human-readable form.")
    var json = false

    func run() throws {
        let output = StandardOutput()
        do {
            let options = MotionOptions(
                udid: udid,
                durationMs: try Milliseconds.parse(duration),
                tolerance: tol,
                keepFramesDirectory: keepFrames.map { URL(fileURLWithPath: $0) },
                json: json
            )
            let environment = ProbeEnvironment.live(simctl: try Simctl.locate(), output: output)
            try CommandExit.finish(MotionRunner(options: options).run(in: environment))
        } catch let error as ProbeError {
            ErrorReporter.report(error, json: json, to: output)
            throw ExitCode(error.exitCode)
        }
    }
}
