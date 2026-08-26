/// Turns an optional `--udid` into exactly one simulator, or into an explanation.
///
/// This is the pinning `agent-device` lacks: its `--device` matches names only, and duplicate
/// names across runtimes are common. Every ambiguity is reported with all of its candidates
/// rather than resolved by a guess, because acting on the wrong simulator fails silently.
public enum DeviceResolver {

    /// - Parameter requested: a UDID, a device name, or `nil` for "the booted one".
    /// - Throws: `ProbeError.noBootedDevice`, `.ambiguousDevice` or `.deviceNotFound`, all
    ///   exit 2.
    public static func resolve(
        _ requested: String?,
        among devices: [SimulatorDevice]
    ) throws -> SimulatorDevice {
        guard let requested else { return try onlyBooted(among: devices) }
        if let exact = devices.first(where: {
            $0.udid.caseInsensitiveCompare(requested) == .orderedSame
        }) {
            return exact
        }
        let named = devices.filter { $0.name.caseInsensitiveCompare(requested) == .orderedSame }
        switch named.count {
        case 0: throw ProbeError.deviceNotFound(requested)
        case 1: return named[0]
        default: throw ProbeError.ambiguousDevice(requested: requested, candidates: named)
        }
    }

    private static func onlyBooted(among devices: [SimulatorDevice]) throws -> SimulatorDevice {
        let booted = devices.filter(\.isBooted)
        switch booted.count {
        case 0: throw ProbeError.noBootedDevice
        case 1: return booted[0]
        default: throw ProbeError.ambiguousDevice(requested: nil, candidates: booted)
        }
    }
}
