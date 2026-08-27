import Foundation
import SimProbeCLI

/// What `simprobe-daemon` was started with.
///
/// Hand-parsed rather than declared with ArgumentParser: this binary is spawned by `simprobe
/// daemon start` and by nothing else, its four flags are always all present, and `@main` on a
/// `ParsableCommand` cannot carry the `macOS 15` availability the gRPC stubs require.
struct DaemonArguments: Equatable {

    let udid: String
    let socketPath: String
    let pidFilePath: String
    let logPath: String
    let idleTimeoutMs: Int

    static let usage = """
        usage: simprobe-daemon --udid <udid> --socket <path> --pid-file <path> \
        --log <path> --idle-timeout-ms <n>

        Started by `simprobe daemon start`; not meant to be run by hand.
        """

    /// - Returns: `nil` when a flag is missing or malformed, which is a caller bug rather than
    ///   anything the daemon can recover from.
    static func parse(_ arguments: [String]) -> DaemonArguments? {
        var values: [String: String] = [:]
        var rest = arguments.dropFirst()
        while let flag = rest.first, flag.hasPrefix("--") {
            rest = rest.dropFirst()
            guard let value = rest.first else { return nil }
            rest = rest.dropFirst()
            values[String(flag.dropFirst(2))] = value
        }
        guard let udid = values["udid"], !udid.isEmpty,
            let socket = values["socket"], !socket.isEmpty,
            let pidFile = values["pid-file"], !pidFile.isEmpty,
            let logPath = values["log"], !logPath.isEmpty,
            let idle = values["idle-timeout-ms"].flatMap(Int.init), idle > 0
        else {
            return nil
        }
        return DaemonArguments(
            udid: udid,
            socketPath: socket,
            pidFilePath: pidFile,
            logPath: logPath,
            idleTimeoutMs: idle
        )
    }
}

/// One line of JSON per event, appended to the daemon's log.
///
/// Single-line and structured because the reader is either `tail -f` during a live run or a
/// person answering "why did `daemon start` time out" from a file written by a process that is
/// no longer around to ask.
struct DaemonLog: Sendable {

    private let path: String

    init(path: String) {
        self.path = path
    }

    func write(_ event: String, _ fields: [String: String] = [:]) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let rendered = ([("t", timestamp), ("event", event)] + fields.sorted { $0.key < $1.key })
            .map { "\"\($0.0)\":\"\(Self.escape($0.1))\"" }
            .joined(separator: ",")
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data("{\(rendered)}\n".utf8))
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
