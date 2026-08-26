/// The simulator families `simprobe devices --platform` can narrow to.
///
/// Narrowing matters because the answer is usually fed straight to `agent-device --udid`:
/// "the first booted simulator" on a machine that also has a watch booted is an Apple Watch,
/// and every subsequent action then lands on the wrong device, silently.
public enum DevicePlatform: String, CaseIterable, Sendable {

    case ios
    case watchos
    case tvos
    case visionos

    /// Every simulator, whatever it runs. The default: narrowing is opt-in.
    case all

    /// Whether a runtime label such as `iOS 26.5` belongs to this platform.
    ///
    /// Matched on the label's prefix rather than on a table of runtime identifiers, so a
    /// runtime released after this code was written is still classified correctly.
    public func matches(runtime: String) -> Bool {
        guard self != .all else { return true }
        let label = runtime.lowercased()
        return prefixes.contains { label.hasPrefix($0) }
    }

    /// Accepted runtime-label prefixes, lowercased.
    ///
    /// visionOS carries two: `simctl` names its runtime `xrOS-2-0`, which reads as `xrOS 2.0`,
    /// while everything user-facing calls the platform visionOS.
    private var prefixes: [String] {
        switch self {
        case .ios: return ["ios"]
        case .watchos: return ["watchos"]
        case .tvos: return ["tvos"]
        case .visionos: return ["visionos", "xros"]
        case .all: return []
        }
    }
}
