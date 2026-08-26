import ArgumentParser

struct DevicesCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "List the simulators on this machine, booted ones first.",
        discussion: """
            Prints one line per simulator, ending with a count. The UDID column is the point: \
            it is what to feed to `agent-device --udid`, whose own --device flag matches names \
            only and cannot separate two simulators that share one.
            """
    )

    @Flag(help: "List only booted simulators.")
    var booted = false

    @Flag(help: "Emit JSON instead of the human-readable table.")
    var json = false

    func run() throws {
        let output = StandardOutput()
        do {
            let lister = SimctlDeviceLister(simctl: try Simctl.locate())
            let options = DevicesOptions(bootedOnly: booted, json: json)
            try CommandExit.finish(DevicesRunner(options: options).run(listing: lister, to: output))
        } catch let error as ProbeError {
            ErrorReporter.report(error, json: json, to: output)
            throw ExitCode(error.exitCode)
        }
    }
}
