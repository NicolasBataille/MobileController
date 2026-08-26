import ArgumentParser

extension ElementPoint: ExpressibleByArgument {
    public init?(argument: String) {
        guard let parsed = try? ElementPoint.parse(argument) else { return nil }
        self = parsed
    }
}

struct FramesCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "frames",
        abstract: "List the on-screen accessibility elements with their 1x coordinates.",
        discussion: """
            The coordinates an accessibility snapshot does not give you. One line per \
            element, banded by vertical position, in the same logical points `shot` writes \
            its image in — so a frame printed here and a pixel read off that image are the \
            same coordinate.

            Elements are named `#accessibilityIdentifier` when the app set one, because that \
            survives a relayout, and `@<index>` otherwise, where the index is the element's \
            position in what idb returned. Zero-size and offscreen elements are dropped, and \
            labels are cut at 40 characters.

            Needs `idb`, which is installed separately: \
            `brew install facebook/fb/idb-companion && pip3 install fb-idb`.
            """
    )

    @Option(help: "UDID or name of the simulator to describe. Defaults to the booted one.")
    var udid: String?

    @Flag(help: "Keep only elements that can be acted on: buttons, fields and switches.")
    var interactive = false

    @Option(help: "Describe only the element under 'x,y' instead of the whole screen.")
    var point: ElementPoint?

    @Flag(help: "Emit JSON instead of the human-readable list.")
    var json = false

    func run() throws {
        try CommandExit.reporting(json: json) { output in
            let resolved = try ProbeSession.live().udid(for: udid)
            let options = FramesOptions(
                udid: resolved,
                interactiveOnly: interactive,
                point: point,
                json: json
            )
            let describer = IdbElementDescriber(idb: try Idb.locate())
            return try FramesRunner(options: options).run(describing: describer, to: output)
        }
    }
}
