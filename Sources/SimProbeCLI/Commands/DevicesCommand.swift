import ArgumentParser

extension DevicePlatform: ExpressibleByArgument {}

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

    @Option(
        help: """
            Keep only this simulator family: ios, watchos, tvos, visionos, or all. \
            Worth pinning: on a machine with a watch booted too, "the first booted \
            simulator" is an Apple Watch.
            """
    )
    var platform: DevicePlatform = .all

    @Flag(help: "Emit JSON instead of the human-readable table.")
    var json = false

    func run() throws {
        try CommandExit.reporting(json: json) { output in
            let lister = SimctlDeviceLister(simctl: try Simctl.locate())
            let options = DevicesOptions(bootedOnly: booted, platform: platform, json: json)
            return try DevicesRunner(options: options).run(listing: lister, to: output)
        }
    }
}
