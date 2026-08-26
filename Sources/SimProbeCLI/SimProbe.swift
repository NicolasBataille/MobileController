import ArgumentParser
import SimProbeCore

/// The `simprobe` command tree.
public struct SimProbe: ParsableCommand {

    public static let configuration = CommandConfiguration(
        commandName: "simprobe",
        abstract: "Answer 'is the screen settled?' about an iOS Simulator, in numbers not pixels.",
        version: SimProbeCore.version,
        subcommands: [WaitStableCommand.self, MotionCommand.self]
    )

    public init() {}
}
