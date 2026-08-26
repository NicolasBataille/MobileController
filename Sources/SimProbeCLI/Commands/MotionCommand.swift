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

            --udid accepts a UDID or a device name; omit it and the single booted \
            simulator is used, or exit 2 lists the candidates when that is ambiguous.
            """
    )

    @Argument(help: "How long to watch for.")
    var duration: String

    @Option(help: "UDID or name of the simulator to watch. Defaults to the booted one.")
    var udid: String?

    @Option(help: "Mean absolute luminance difference below which a screen counts as quiet.")
    var tol: Double = FrameDiff.defaultTolerance

    @Option(
        help: """
            Directory to write one PNG per sample into, up to \
            \(MotionOptions.defaultKeepFramesCap) of them. Nothing is written without it.
            """
    )
    var keepFrames: String?

    @Flag(help: "Emit one line of JSON instead of the human-readable form.")
    var json = false

    func run() throws {
        try CommandExit.reporting(json: json) { output in
            let session = try ProbeSession.live()
            let options = MotionOptions(
                udid: try session.udid(for: udid),
                durationMs: try Milliseconds.parse(duration),
                tolerance: tol,
                keepFramesDirectory: keepFrames.map { URL(fileURLWithPath: $0) },
                json: json
            )
            return try MotionRunner(options: options).run(in: session.environment(output: output))
        }
    }
}
