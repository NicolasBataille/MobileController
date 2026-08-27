import Darwin
import Foundation

/// One line of JSON per event, appended to the daemon's log.
///
/// Single-line and structured because the reader is either `tail -f` during a live run or a
/// person answering "why did `daemon start` time out" from a file written by a process that is
/// no longer around to ask.
///
/// Every write opens the file, appends and closes it: the daemon logs a handful of lines an
/// hour, the cost is invisible next to that, and a descriptor held open for ten minutes is a
/// descriptor pointing at whatever the file has become since.
public struct DaemonLog: Sendable {

    private let path: String

    public init(path: String) {
        self.path = path
    }

    /// Appends one event. Failures are swallowed on purpose: a daemon that cannot write its log
    /// still has a simulator to drive, and there is nowhere better to report the failure to.
    public func write(_ event: String, _ fields: [String: String] = [:]) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let rendered = ([("t", timestamp), ("event", event)] + fields.sorted { $0.key < $1.key })
            .map { "\"\(Self.escape($0.0))\":\"\(Self.escape($0.1))\"" }
            .joined(separator: ",")
        guard let descriptor = try? SecureFile.openForAppending(atPath: path) else { return }
        defer { close(descriptor) }
        var bytes = Array("{\(rendered)}\n".utf8)[...]
        while !bytes.isEmpty {
            let written = bytes.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress, $0.count)
            }
            switch SocketIO.classify(count: written, errno: errno) {
            case .bytes(let count): bytes = bytes.dropFirst(count)
            case .interrupted: continue
            case .timedOut, .closed, .failed: return
            }
        }
    }

    /// JSON string escaping, control characters included.
    ///
    /// A companion error can carry a tab or a stray `\u{1b}` from a terminal-coloured message,
    /// and a raw control byte inside a quoted string is not JSON: a log line that `jq` refuses
    /// is a log line nobody reads on the day it matters.
    static func escape(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": escaped += #"\\"#
            case "\"": escaped += #"\""#
            case "\n": escaped += #"\n"#
            case "\r": escaped += #"\r"#
            case "\t": escaped += #"\t"#
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: #"\u%04x"#, scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return escaped
    }
}
