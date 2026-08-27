import Darwin
import Foundation

/// The filesystem checks that stand between this daemon and a local attacker.
///
/// Everything the daemon owns lives in a world-readable temporary directory, which is where
/// every classic local escalation happens: a symlink planted where a log file is about to be
/// created, a directory pre-made with permissive modes, a socket path swapped for someone
/// else's file between the check and the `unlink`. None of it is exotic and all of it is cheap
/// to refuse — as long as the refusal happens on the *node*, with `lstat` and `O_NOFOLLOW`,
/// rather than on the path.
public enum SecureFile {

    /// The mode every daemon directory must end up with: owner only.
    public static let directoryMode: mode_t = 0o700

    /// The mode the log and the pidfile are created with.
    public static let fileMode: mode_t = 0o600

    /// Which node a path names, right now.
    ///
    /// A device and inode pair rather than the path itself, because the path is exactly what an
    /// attacker gets to change: two `lstat`s that agree prove the node did not move between them
    /// in a way no amount of re-reading the path can.
    public struct NodeIdentity: Equatable, Sendable {

        public let device: dev_t
        public let inode: ino_t

        public init(device: dev_t, inode: ino_t) {
            self.device = device
            self.inode = inode
        }
    }

    /// - Returns: the node a path names without following a final symlink, or `nil` when there
    ///   is nothing there.
    public static func identity(ofPath path: String) -> NodeIdentity? {
        guard let status = lstatus(ofPath: path) else { return nil }
        return NodeIdentity(device: status.st_dev, inode: status.st_ino)
    }

    /// Whether a path names a socket this user owns — the only thing the daemon may unlink.
    public static func isOwnedSocket(atPath path: String) -> Bool {
        guard let status = lstatus(ofPath: path) else { return false }
        return status.st_mode & S_IFMT == S_IFSOCK && status.st_uid == getuid()
    }

    /// Unlinks a path only while it still names the node it named when `identity` was taken.
    ///
    /// - Returns: whether the node was removed.
    @discardableResult
    public static func unlink(path: String, matching identity: NodeIdentity?) -> Bool {
        guard let identity, self.identity(ofPath: path) == identity else { return false }
        return Darwin.unlink(path) == 0
    }

    /// Proves a directory is a real directory, owned by this user, mode `0700` — fixing the mode
    /// when it is ours to fix.
    ///
    /// - Throws: `ProbeError.captureFailed` (exit 5), naming the path. A directory somebody else
    ///   can write to is a directory somebody else can put a socket in, and the socket is an
    ///   unauthenticated command channel onto a simulator.
    public static func requirePrivateDirectory(atPath path: String) throws {
        guard let status = lstatus(ofPath: path) else {
            throw ProbeError.captureFailed("no directory at \(path)")
        }
        guard status.st_mode & S_IFMT == S_IFDIR else {
            throw ProbeError.captureFailed(
                "\(path) is not a directory; refusing to put a command socket there")
        }
        guard status.st_uid == getuid() else {
            throw ProbeError.captureFailed(
                "\(path) belongs to uid \(status.st_uid), not to \(getuid())")
        }
        guard status.st_mode & 0o777 != directoryMode else { return }
        guard chmod(path, directoryMode) == 0 else {
            throw ProbeError.captureFailed(
                "\(path) is mode \(String(status.st_mode & 0o777, radix: 8)) "
                    + "and could not be made 0700: \(errno)")
        }
    }

    /// Opens a file for appending, creating it `0600` and never following a symlink.
    ///
    /// - Throws: `ProbeError.captureFailed` (exit 5), naming the path. A log file that is a
    ///   symlink is an append primitive pointed at whatever the link names.
    public static func openForAppending(atPath path: String) throws -> Int32 {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, fileMode)
        guard descriptor >= 0 else {
            throw ProbeError.captureFailed("could not open \(path) for appending: \(errno)")
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG,
            status.st_uid == getuid()
        else {
            close(descriptor)
            throw ProbeError.captureFailed("\(path) is not a regular file owned by this user")
        }
        return descriptor
    }

    /// Replaces a file's contents, creating it `0600` and never following a symlink.
    ///
    /// - Throws: `ProbeError.captureFailed` (exit 5), naming the path.
    public static func write(_ data: Data, toPath path: String) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, fileMode)
        guard descriptor >= 0 else {
            throw ProbeError.captureFailed("could not write \(path): \(errno)")
        }
        defer { close(descriptor) }
        // A pre-existing file keeps the mode it was created with, and this one may have been
        // created by an older build.
        fchmod(descriptor, fileMode)
        var remaining = Array(data)[...]
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress, $0.count)
            }
            switch SocketIO.classify(count: written, errno: errno) {
            case .bytes(let count): remaining = remaining.dropFirst(count)
            case .interrupted: continue
            case .timedOut, .closed, .failed:
                throw ProbeError.captureFailed("could not write all of \(path): \(errno)")
            }
        }
    }

    private static func lstatus(ofPath path: String) -> stat? {
        var status = stat()
        guard lstat(path, &status) == 0 else { return nil }
        return status
    }
}
