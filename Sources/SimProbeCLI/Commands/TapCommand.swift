import ArgumentParser

extension TapTarget: ExpressibleByArgument {
    public init?(argument: String) {
        guard let parsed = try? TapTarget.parse(argument) else { return nil }
        self = parsed
    }
}

struct TapCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "tap",
        abstract: "Tap an element or a coordinate through the warm daemon, in about a millisecond.",
        discussion: """
            Takes the refs `frames` and `tree` print: `#accessibilityIdentifier` when the app \
            set one, `@<index>` otherwise, or a bare `x,y` in the same logical points those \
            commands report. A ref is resolved against a fresh tree and the tap lands on the \
            centre of the element's frame.

            A coordinate tap is swallowed silently by anything drawn over it — a keyboard, a \
            sheet, a modal — on this engine and on XCUITest alike. Verify the result rather \
            than assuming it: `--wait-stable` chains `simprobe wait-stable` onto the tap, and \
            its exit code (3 on timeout) becomes this command's.

            Needs a running daemon: `simprobe daemon start`.
            """
    )

    @Argument(help: "What to tap: #id, @index, or x,y.")
    var target: TapTarget

    @Option(help: "UDID or name of the simulator. Defaults to the booted one.")
    var udid: String?

    @Flag(help: "After tapping, poll until the screen stops changing.")
    var waitStable = false

    @Flag(help: "Emit one line of JSON instead of the human-readable form.")
    var json = false

    func run() throws {
        try CommandExit.reporting(json: json) { output in
            let session = try ProbeSession.live()
            let resolved = try session.udid(for: udid)
            let options = TapOptions(
                udid: resolved,
                target: target,
                waitStable: waitStable,
                json: json
            )
            return try TapRunner(options: options).run(
                through: DaemonSession(udid: resolved).client,
                in: session.environment(output: output)
            )
        }
    }
}
