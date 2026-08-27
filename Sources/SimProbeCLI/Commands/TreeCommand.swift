import ArgumentParser

struct TreeCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "tree",
        abstract: "List the on-screen elements through the warm daemon, in about 70 ms.",
        discussion: """
            The output `frames` prints, from the daemon instead of from an `idb` process: one \
            line per element, banded by vertical position, in the same logical points `shot` \
            writes its image in. Refs printed here are what `tap` takes.

            The node count is **not** comparable with an agent-device snapshot: idb's tree is \
            leaner by design and skips elements XCUITest reports. Never diff the two counts, \
            and never use either to prove an element is absent.

            Needs a running daemon: `simprobe daemon start`.
            """
    )

    @Option(help: "UDID or name of the simulator. Defaults to the booted one.")
    var udid: String?

    @Flag(help: "Keep only elements that can be acted on: buttons, fields and switches.")
    var interactive = false

    @Flag(help: "Emit JSON instead of the human-readable list.")
    var json = false

    func run() throws {
        try CommandExit.reporting(json: json) { output in
            let resolved = try ProbeSession.live().udid(for: udid)
            let options = FramesOptions(udid: resolved, interactiveOnly: interactive, json: json)
            return try FramesRunner(options: options).run(
                describing: DaemonSession(udid: resolved).describer, to: output)
        }
    }
}
