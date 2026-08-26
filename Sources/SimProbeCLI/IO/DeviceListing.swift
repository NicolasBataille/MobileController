/// One simulator, as `simprobe devices` reports it.
public struct SimulatorDevice: Equatable, Sendable {

    public let udid: String
    public let name: String

    /// Human-readable runtime, e.g. `iOS 26.5`.
    public let runtime: String

    public let isBooted: Bool
    public let isAvailable: Bool

    public init(udid: String, name: String, runtime: String, isBooted: Bool, isAvailable: Bool) {
        self.udid = udid
        self.name = name
        self.runtime = runtime
        self.isBooted = isBooted
        self.isAvailable = isAvailable
    }
}

/// Enumerating the simulators on this machine.
public protocol DeviceListing {
    func devices() throws -> [SimulatorDevice]
}
