import ArgumentParser

/// `simprobe daemon start | stop | status`.
struct DaemonCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Run a warm idb connection so `tap` and `tree` cost milliseconds.",
        discussion: """
            The daemon holds one gRPC connection to `idb_companion` open, which turns a 375 ms \
            tap into ~1 ms and a 623 ms accessibility read into ~70 ms. It is worth starting \
            for a loop — observe, act, observe — and not worth starting for a single command.

            Screenshots deliberately keep going through `simctl`, daemon or not: idb's own \
            screenshot breaks once its companion outlives a simulator reboot, and reconnecting \
            does not heal it. `daemon start` smoke-tests both halves before reporting ready.

            Needs `idb`: `brew install facebook/fb/idb-companion && pip3 install fb-idb`.
            """,
        subcommands: [Start.self, Stop.self, Status.self]
    )

    struct Start: ParsableCommand {

        static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Start the daemon and prove it works before reporting ready."
        )

        @Option(help: "UDID or name of the simulator to attach to. Defaults to the booted one.")
        var udid: String?

        @Option(help: "Exit after this long with no request. Accepts 250, 60ms, 10m-style values.")
        var idleTimeout: String = "600s"

        @Flag(help: "Emit one line of JSON instead of the human-readable form.")
        var json = false

        func run() throws {
            try CommandExit.reporting(json: json) { output in
                let session = try ProbeSession.live()
                let resolved = try session.udid(for: udid)
                let daemon = DaemonSession(udid: resolved)
                let options = DaemonLaunchOptions(
                    udid: resolved,
                    idleTimeoutMs: try Milliseconds.parse(idleTimeout),
                    json: json
                )
                return try DaemonRunner(launcher: try session.daemonLauncher(for: daemon))
                    .start(options, to: output)
            }
        }
    }

    struct Stop: ParsableCommand {

        static let configuration = CommandConfiguration(
            commandName: "stop",
            abstract: "Stop the daemon for a simulator. Exit 0 whether or not one was running."
        )

        @Option(help: "UDID or name of the simulator. Defaults to the booted one.")
        var udid: String?

        @Flag(help: "Emit one line of JSON instead of the human-readable form.")
        var json = false

        func run() throws {
            try CommandExit.reporting(json: json) { output in
                let session = try ProbeSession.live()
                let resolved = try session.udid(for: udid)
                let daemon = DaemonSession(udid: resolved)
                return try DaemonRunner(launcher: try session.daemonLauncher(for: daemon))
                    .stop(udid: resolved, json: json, to: output)
            }
        }
    }

    struct Status: ParsableCommand {

        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Say whether a daemon is running, and for how long."
        )

        @Option(help: "UDID or name of the simulator. Defaults to the booted one.")
        var udid: String?

        @Flag(help: "Emit one line of JSON instead of the human-readable form.")
        var json = false

        func run() throws {
            try CommandExit.reporting(json: json) { output in
                let session = try ProbeSession.live()
                let resolved = try session.udid(for: udid)
                let daemon = DaemonSession(udid: resolved)
                return try DaemonRunner(launcher: try session.daemonLauncher(for: daemon))
                    .status(udid: resolved, json: json, to: output)
            }
        }
    }
}
