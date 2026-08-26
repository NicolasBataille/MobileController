import Foundation

/// What `devices` was asked to do.
public struct DevicesOptions: Equatable, Sendable {
    public let bootedOnly: Bool
    public let json: Bool

    public init(bootedOnly: Bool = false, json: Bool = false) {
        self.bootedOnly = bootedOnly
        self.json = json
    }
}

/// Lists the simulators on this machine, booted ones first.
public struct DevicesRunner {

    private let options: DevicesOptions

    public init(options: DevicesOptions) {
        self.options = options
    }

    public func run(listing: any DeviceListing, to output: any OutputWriting) throws -> Int32 {
        let all = try listing.devices()
        let shown = (options.bootedOnly ? all.filter(\.isBooted) : all).sorted(by: Self.ordering)
        if options.json {
            output.writeLine(try JSONLine.encode(shown.map(Report.init)))
        } else {
            table(for: shown, bootedCount: shown.filter(\.isBooted).count).forEach(output.writeLine)
        }
        return 0
    }

    /// Booted first, then by name: the booted device is the one a caller almost always wants.
    private static func ordering(_ lhs: SimulatorDevice, _ rhs: SimulatorDevice) -> Bool {
        (lhs.isBooted ? 0 : 1, lhs.name, lhs.runtime) < (
            rhs.isBooted ? 0 : 1, rhs.name, rhs.runtime
        )
    }

    private func table(for devices: [SimulatorDevice], bootedCount: Int) -> [String] {
        let nameWidth = (devices.map(\.name.count).max() ?? 0) + 3
        let runtimeWidth = (devices.map(\.runtime.count).max() ?? 0) + 3
        let rows = devices.map { device in
            (device.isBooted ? "BOOTED" : "      ") + "  "
                + device.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
                + device.runtime.padding(toLength: runtimeWidth, withPad: " ", startingAt: 0)
                + device.udid
        }
        let noun = devices.count == 1 ? "device" : "devices"
        return rows + ["\(devices.count) \(noun), \(bootedCount) booted"]
    }

    private struct Report: Encodable {
        let udid: String
        let name: String
        let runtime: String
        let booted: Bool
        let available: Bool

        init(_ device: SimulatorDevice) {
            udid = device.udid
            name = device.name
            runtime = device.runtime
            booted = device.isBooted
            available = device.isAvailable
        }
    }
}
