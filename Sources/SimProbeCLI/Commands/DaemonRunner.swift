import Foundation

/// Prints what the lifecycle verbs found.
///
/// Separated from the launcher because starting a daemon and describing one are different jobs:
/// the launcher is asserted on the *sequence* it performs, this on the line it writes.
public struct DaemonRunner {

    private let launcher: DaemonLauncher

    public init(launcher: DaemonLauncher) {
        self.launcher = launcher
    }

    public func start(_ options: DaemonLaunchOptions, to output: any OutputWriting) throws -> Int32
    {
        let report = try launcher.start(options)
        if options.json {
            output.writeLine(try JSONLine.encode(StartReport(report)))
        } else {
            let reused = report.wasAlreadyRunning ? ", already running" : ""
            output.writeLine(
                "daemon ready (\(report.udid), tree \(report.elementCount) elements, "
                    + "\(report.ms) ms\(reused))"
            )
        }
        return 0
    }

    /// Exit 0 whether or not anything was running: `stop` is idempotent by design, because the
    /// caller's intent — no daemon afterwards — is satisfied either way.
    public func stop(udid: String, json: Bool, to output: any OutputWriting) throws -> Int32 {
        let stopped = try launcher.stop(udid: udid)
        if json {
            output.writeLine(try JSONLine.encode(StopReport(udid: udid, stopped: stopped)))
        } else {
            output.writeLine(
                stopped ? "daemon stopped (\(udid))" : "no daemon running (\(udid))")
        }
        return 0
    }

    /// Exit 0 in both states: absence is a result, not an error, and a caller that scripts
    /// `daemon status || daemon start` wants to branch on the text, not on a failed command.
    public func status(udid: String, json: Bool, to output: any OutputWriting) throws -> Int32 {
        let status = launcher.status(udid: udid)
        if json {
            output.writeLine(try JSONLine.encode(StatusReport(status)))
        } else if let pid = status.pid {
            let uptime = status.uptimeMs.map { " up \(Self.duration(ms: $0))" } ?? ""
            output.writeLine("running (\(udid), pid \(pid),\(uptime))")
        } else {
            output.writeLine("not running (\(udid))")
        }
        return 0
    }

    /// `3m12s`, `45s`, `2h04m` — the shape a person reads an uptime in.
    static func duration(ms: Int) -> String {
        let seconds = max(ms, 0) / 1_000
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m\(String(format: "%02d", seconds % 60))s" }
        return "\(minutes / 60)h\(String(format: "%02d", minutes % 60))m"
    }

    private struct StartReport: Encodable {
        let alreadyRunning: Bool
        let elements: Int
        let ms: Int
        let udid: String

        init(_ report: DaemonStartReport) {
            alreadyRunning = report.wasAlreadyRunning
            elements = report.elementCount
            ms = report.ms
            udid = report.udid
        }
    }

    private struct StopReport: Encodable {
        let udid: String
        let stopped: Bool
    }

    private struct StatusReport: Encodable {
        let pid: Int32?
        let running: Bool
        let udid: String
        let uptimeMs: Int?

        init(_ status: DaemonStatus) {
            pid = status.pid
            running = status.isRunning
            udid = status.udid
            uptimeMs = status.uptimeMs
        }
    }
}
