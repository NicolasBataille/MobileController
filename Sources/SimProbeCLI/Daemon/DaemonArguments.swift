import Foundation

/// What `simprobe-daemon` was started with.
///
/// Hand-parsed rather than declared with ArgumentParser: this binary is spawned by `simprobe
/// daemon start` and by nothing else, its five flags are always all present, and `@main` on a
/// `ParsableCommand` cannot carry the `macOS 15` availability the gRPC stubs require.
///
/// It lives in the CLI library rather than in the daemon for the same reason the wire protocol
/// does: `DaemonLauncher` writes this command line and this type reads it, they are two halves
/// of one contract, and a test bundle that links gRPC would cost nineteen minutes to build.
public struct DaemonArguments: Equatable, Sendable {

    public let udid: String
    public let socketPath: String
    public let pidFilePath: String
    public let logPath: String
    public let idleTimeoutMs: Int

    public init(
        udid: String,
        socketPath: String,
        pidFilePath: String,
        logPath: String,
        idleTimeoutMs: Int
    ) {
        self.udid = udid
        self.socketPath = socketPath
        self.pidFilePath = pidFilePath
        self.logPath = logPath
        self.idleTimeoutMs = idleTimeoutMs
    }

    public static let usage = """
        usage: simprobe-daemon --udid <udid> --socket <path> --pid-file <path> \
        --log <path> --idle-timeout-ms <n>

        Started by `simprobe daemon start`; not meant to be run by hand.
        """

    /// - Returns: `nil` when a flag is missing or malformed, which is a caller bug rather than
    ///   anything the daemon can recover from.
    public static func parse(_ arguments: [String]) -> DaemonArguments? {
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
