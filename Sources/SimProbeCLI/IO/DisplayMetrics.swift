import Foundation

/// Reading a simulator's framebuffer scale.
///
/// `shot` needs it to turn a captured pixel size into a logical point size. The scale is not
/// hardcoded to 3: it is 3 on current iPhone hardware but 2 on several iPads and older devices,
/// and a constant would silently mis-size every coordinate read off those screens.
public protocol DisplayMetricsProviding {
    func scale(udid: String) throws -> Double
}

/// Reads the scale out of `xcrun simctl io <udid> enumerate`.
///
/// `simctl list devicetypes -j` does not carry a point size, but `enumerate` describes each
/// connected screen and reports `Preferred UI Scale` for it. Only the `Integrated` screen is
/// considered: the same output also describes a CarPlay screen and a TV-out screen, both at
/// scale 1, and picking the wrong one halves or thirds every reported coordinate.
public struct SimctlDisplayMetrics: DisplayMetricsProviding {

    private let simctl: String
    private let runner: any ProcessRunning

    public init(simctl: String, runner: any ProcessRunning = SystemProcessRunner()) {
        self.simctl = simctl
        self.runner = runner
    }

    public func scale(udid: String) throws -> Double {
        let result = try runner.run(simctl, ["io", udid, "enumerate"])
        guard result.status == 0 else {
            throw ProbeError.simctlFailed(
                command: "io \(udid) enumerate",
                detail: result.failureDetail
            )
        }
        return try Self.integratedScreenScale(in: result.standardOutputText)
    }

    /// - Throws: `ProbeError.simctlFailed` (exit 2) when no integrated screen is described,
    ///   which means the device is not the kind of thing `shot` can measure.
    static func integratedScreenScale(in text: String) throws -> Double {
        var isIntegrated = false
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let type = value(of: "Screen Type", in: trimmed) {
                isIntegrated = type == "Integrated"
            }
            if isIntegrated, let scale = value(of: "Preferred UI Scale", in: trimmed),
                let parsed = Double(scale), parsed > 0
            {
                return parsed
            }
        }
        throw ProbeError.simctlFailed(
            command: "io … enumerate",
            detail: "no integrated screen with a 'Preferred UI Scale' was reported"
        )
    }

    private static func value(of key: String, in line: String) -> String? {
        guard line.hasPrefix(key + ":") else { return nil }
        return line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
    }
}
