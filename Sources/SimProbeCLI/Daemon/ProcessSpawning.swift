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
        // `O_NOFOLLOW|O_CREAT|O_APPEND`, mode 0600, rather than `createFile` plus a
        // `FileHandle`: the log sits in a shared temporary directory, and a symlink planted at
        // that path would turn the daemon's stdout into an append primitive aimed at whatever
        // the link names.
        let descriptor = try SecureFile.openForAppending(atPath: logPath)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
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

    /// What a signallable executable path has to end in.
    ///
    /// A second lock on the same door as the pid check: a pidfile whose `executable` has been
    /// rewritten to `/bin/launchd` names a live process whose path would otherwise match itself.
    /// Nothing this tool signals is ever anything but its own daemon.
    public static let daemonSuffix = "/" + DaemonExecutable.name

    /// Whether `pid` is a live process running `executable`, and `executable` is a daemon.
    ///
    /// - Parameter mustEndWith: the suffix the recorded path has to carry. Defaulted rather than
    ///   hard-coded so the check itself can be tested against a process that actually exists.
    public static func isRunning(
        pid: Int32,
        executable: String,
        mustEndWith suffix: String = daemonSuffix
    ) -> Bool {
        guard executable.hasSuffix(suffix) else { return false }
        return executablePath(of: pid).map { $0 == executable } ?? false
    }
}

/// Whether a recorded process is still alive, and asking it to stop — behind a protocol so the
/// stop sequence can be asserted without a process to kill.
public protocol ProcessLiveness: Sendable {

    func isRunning(_ record: DaemonRecord) -> Bool

    /// `SIGTERM`, and only ever to a process that still passes `isRunning`.
    func terminate(_ record: DaemonRecord)
}

public struct SystemProcessLiveness: ProcessLiveness {

    public init() {}

    public func isRunning(_ record: DaemonRecord) -> Bool {
        ProcessIdentity.isRunning(pid: record.pid, executable: record.executable)
    }

    public func terminate(_ record: DaemonRecord) {
        guard isRunning(record) else { return }
        kill(record.pid, SIGTERM)
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

    /// Written `0600` and without following a symlink, like the log and the socket beside it.
    /// The directory is already private to this user; this is the second lock on the same door.
    public func write(to path: String) throws {
        try SecureFile.write(Data(try JSONLine.encode(self).utf8), toPath: path)
    }

    /// - Returns: `nil` when there is no pidfile, or it is not readable as one. An unreadable
    ///   pidfile is treated as no pidfile: it names no process anyone should signal.
    public static func read(from path: String) -> DaemonRecord? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(DaemonRecord.self, from: data)
    }

    /// Removes a pidfile only when it is still *this* process's own.
    ///
    /// A daemon that exits removes its pidfile on the way out. Between the two, a second daemon
    /// may have started and written its own — and deleting that one leaves a live daemon nobody
    /// can stop. The file says whose it is; that is the whole check.
    ///
    /// - Returns: whether the file was removed.
    @discardableResult
    public static func removeIfOwned(path: String, pid: Int32) -> Bool {
        guard read(from: path)?.pid == pid else { return false }
        return (try? FileManager.default.removeItem(atPath: path)) != nil
    }
}
