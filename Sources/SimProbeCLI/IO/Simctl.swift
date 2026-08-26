import Foundation

/// Locating `simctl` once, rather than paying `xcrun`'s search on every capture.
public enum Simctl {

    /// Resolves the absolute path to `simctl`.
    ///
    /// - Throws: `ProbeError.simctlUnavailable` (exit 2) when Xcode's command line tools are
    ///   missing or misconfigured, which is an environment problem and not a usage error.
    public static func locate(runner: any ProcessRunning = SystemProcessRunner()) throws -> String {
        let result = try runner.run("/usr/bin/xcrun", ["-f", "simctl"])
        let path = result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, !path.isEmpty else {
            throw ProbeError.simctlUnavailable(result.failureDetail)
        }
        return path
    }
}
