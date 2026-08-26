import Foundation

/// The per-invocation setup every verb shares: locating `simctl` once, and turning an optional
/// `--udid` into exactly one simulator.
public struct ProbeSession {

    private let simctl: String
    private let listing: any DeviceListing

    public init(simctl: String, listing: any DeviceListing) {
        self.simctl = simctl
        self.listing = listing
    }

    /// - Throws: `ProbeError.simctlUnavailable` (exit 2) when Xcode's tools are missing.
    public static func live() throws -> ProbeSession {
        let simctl = try Simctl.locate()
        return ProbeSession(simctl: simctl, listing: SimctlDeviceLister(simctl: simctl))
    }

    /// Resolves what the user asked for into a UDID.
    ///
    /// A value that is already a canonical UDID is used as-is, without enumerating the machine:
    /// `simctl list devices --json` costs the better part of a second, and paying it to confirm
    /// a UDID the caller already holds would be charged to every single invocation.
    public func udid(for requested: String?) throws -> String {
        if let requested, UDID.isCanonical(requested) { return requested }
        return try DeviceResolver.resolve(requested, among: try listing.devices()).udid
    }

    public func environment(output: any OutputWriting) -> ProbeEnvironment {
        ProbeEnvironment.live(simctl: simctl, output: output)
    }

    public var displayMetrics: any DisplayMetricsProviding {
        SimctlDisplayMetrics(simctl: simctl)
    }
}

/// Recognises the canonical `8-4-4-4-12` hexadecimal simulator identifier.
///
/// Checked structurally rather than with a regular expression so that no UDID-shaped pattern
/// has to appear in a tracked file.
enum UDID {

    private static let groupLengths = [8, 4, 4, 4, 12]

    static func isCanonical(_ text: String) -> Bool {
        let groups = text.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == groupLengths.count else { return false }
        return zip(groups, groupLengths).allSatisfy { group, length in
            group.count == length && group.allSatisfy(\.isHexDigit)
        }
    }
}
