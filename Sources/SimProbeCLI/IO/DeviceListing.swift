import Foundation

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

extension SimulatorDevice {
    /// `name (udid)`, the form every disambiguation message uses.
    public var summary: String { "\(name) (\(udid))" }

    /// The version numbers in `runtime`: `iOS 26.5` reads as `[26, 5]`.
    ///
    /// Empty when the label carries no number, which happens only for a runtime identifier
    /// that did not fit the expected shape and was passed through untouched.
    public var runtimeVersion: [Int] {
        runtime.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }
}

/// The one place device order is decided, so the list a verb prints and the list it resolves
/// against cannot disagree.
public enum DeviceOrder {

    /// Newest runtime first, then by name.
    ///
    /// `simctl` returns an unordered dictionary of runtimes, so an explicit order is the only
    /// way the output is reproducible. The runtime is compared as a version *number*: as
    /// strings `"iOS 9.0" > "iOS 26.5"`, which silently inverted "newest first" on any machine
    /// still carrying a single-digit runtime.
    public static func byNewestRuntimeThenName(
        _ lhs: SimulatorDevice,
        _ rhs: SimulatorDevice
    ) -> Bool {
        let (left, right) = (lhs.runtimeVersion, rhs.runtimeVersion)
        if left != right { return isDescending(left, right) }
        // Same numbers: order by the label, so two families that share a version still have a
        // total order, and only then by name.
        return lhs.runtime == rhs.runtime ? lhs.name < rhs.name : lhs.runtime > rhs.runtime
    }

    /// Booted first, then `byNewestRuntimeThenName`: the booted device is the one a caller
    /// almost always wants, and it is what the pinning recipe reads the first entry of.
    public static func bootedFirst(_ lhs: SimulatorDevice, _ rhs: SimulatorDevice) -> Bool {
        lhs.isBooted == rhs.isBooted
            ? byNewestRuntimeThenName(lhs, rhs)
            : lhs.isBooted
    }

    private static func isDescending(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        for (left, right) in zip(lhs, rhs) where left != right { return left > right }
        return lhs.count > rhs.count
    }
}

/// Lists simulators through `xcrun simctl list devices --json`.
public struct SimctlDeviceLister: DeviceListing {

    private let simctl: String
    private let runner: any ProcessRunning

    public init(simctl: String, runner: any ProcessRunning = SystemProcessRunner()) {
        self.simctl = simctl
        self.runner = runner
    }

    public func devices() throws -> [SimulatorDevice] {
        let result = try runner.run(simctl, ["list", "devices", "--json"])
        guard result.status == 0 else {
            throw ProbeError.simctlFailed(
                command: "list devices --json",
                detail: result.failureDetail
            )
        }
        return try Self.parse(result.standardOutput)
    }

    static func parse(_ data: Data) throws -> [SimulatorDevice] {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw ProbeError.simctlFailed(
                command: "list devices --json",
                detail: "unreadable JSON: \(error.localizedDescription)"
            )
        }
        return payload.devices.flatMap { runtime, entries in
            entries.map { $0.device(runtime: Self.runtimeLabel(runtime)) }
        }
        .sorted(by: DeviceOrder.byNewestRuntimeThenName)
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-5` reads as `iOS 26.5`.
    ///
    /// Anything that does not fit that shape is passed through untouched rather than mangled:
    /// an unrecognised runtime identifier is still more useful than a wrong one.
    static func runtimeLabel(_ identifier: String) -> String {
        guard let last = identifier.split(separator: ".").last else { return identifier }
        let parts = last.split(separator: "-")
        guard parts.count > 1 else { return String(last) }
        return "\(parts[0]) \(parts.dropFirst().joined(separator: "."))"
    }

    private struct Payload: Decodable {
        let devices: [String: [Entry]]
    }

    private struct Entry: Decodable {
        let udid: String
        let name: String
        let state: String
        let isAvailable: Bool?

        func device(runtime: String) -> SimulatorDevice {
            SimulatorDevice(
                udid: udid,
                name: name,
                runtime: runtime,
                isBooted: state == "Booted",
                isAvailable: isAvailable ?? true
            )
        }
    }
}
