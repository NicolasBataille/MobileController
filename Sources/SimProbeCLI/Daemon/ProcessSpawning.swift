import Darwin
import Foundation

/// Starting a long-lived child that outlives this process, behind a protocol so the lifecycle
/// verbs can be tested without spawning anything.
public protocol ProcessSpawning: Sendable {

    /// - Parameter logPath: where the child's stdout and stderr are appended.
    /// - Returns: the child's process identifier.
    func spawnDetached(_ executable: String, _ arguments: [String], logPath: String) throws -> Int32
}

/// The real one: `Process`, both streams appended to the daemon's log, and no wait.
///
/// Not waited on and not reaped: the child is meant to outlive the CLI invocation that started
/// it, and once this process exits `launchd` adopts it.
public struct DetachedProcessSpawner: ProcessSpawning {

    public init() {}

    public func spawnDetached(_ executable: String, _ arguments: [String], logPath: String) throws
        -> Int32
    {
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            process.standardOutput = handle
            process.standardError = handle
        }
        // Nothing is ever read from the child's stdin, and leaving it on the terminal would let
        // a backgrounded daemon stop the shell with SIGTTIN.
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ProbeError.captureFailed(
                "could not start \(executable): \(error.localizedDescription)")
        }
        return process.processIdentifier
    }
}

/// Who a process identifier actually belongs to.
///
/// A pidfile outlives a crash, and the number in it is recycled: signalling it blind would
/// eventually take down whatever inherited that pid. `simprobe daemon stop` therefore only ever
/// signals a pid whose executable is still the daemon it wrote down.
public enum ProcessIdentity {

    /// The executable path of a running process, or `nil` if there is no such process.
    public static func executablePath(of pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer[0..<Int(length)], as: UTF8.self)
    }

    /// Whether `pid` is a live process running `executable`.
    public static func isRunning(pid: Int32, executable: String) -> Bool {
        executablePath(of: pid).map { $0 == executable } ?? false
    }
}

/// What a daemon wrote down about itself, so `stop` can find it when the socket is already gone.
public struct DaemonRecord: Codable, Equatable, Sendable {

    public let pid: Int32
    public let udid: String

    /// The daemon binary, checked against the live process before anything is signalled.
    public let executable: String

    public init(pid: Int32, udid: String, executable: String) {
        self.pid = pid
        self.udid = udid
        self.executable = executable
    }

    public func write(to path: String) throws {
        do {
            try Data(try JSONLine.encode(self).utf8).write(to: URL(fileURLWithPath: path))
        } catch {
            throw ProbeError.captureFailed(
                "could not write \(path): \(error.localizedDescription)")
        }
    }

    /// - Returns: `nil` when there is no pidfile, or it is not readable as one. An unreadable
    ///   pidfile is treated as no pidfile: it names no process anyone should signal.
    public static func read(from path: String) -> DaemonRecord? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(DaemonRecord.self, from: data)
    }
}
