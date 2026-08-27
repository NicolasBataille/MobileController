import Foundation

/// Where a daemon's socket, pidfile and log live.
///
/// One directory per user under the temporary directory, `0700`: the socket is an unauthenticated
/// command channel onto a simulator, and a world-writable one would let any local process tap the
/// screen. `TMPDIR` is already per-user on macOS; the mode makes that explicit rather than assumed.
public struct DaemonPaths: Equatable, Sendable {

    /// The subdirectory everything lives in.
    public static let directoryName = "simprobe"

    /// The longest a unix socket path may be.
    ///
    /// `sun_path` is 104 bytes including the terminator, so 103 characters are usable.
    /// `$TMPDIR/simprobe/<udid>.sock` measures 100 on macOS 26 — a four-byte margin, which is
    /// close enough that a longer `TMPDIR` on some other machine would fail at `bind()` with an
    /// error naming neither the path nor its length.
    public static let socketPathLimit = 103

    /// Where `$TMPDIR` cannot be used because the resulting socket path would not fit.
    static let fallbackBase = URL(fileURLWithPath: "/tmp", isDirectory: true)

    private let base: URL

    public init(base: URL) {
        self.base = base
    }

    /// The real one, rooted at `$TMPDIR`.
    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> DaemonPaths
    {
        let temporary = environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        return DaemonPaths(base: temporary ?? FileManager.default.temporaryDirectory)
    }

    public var directory: URL { base.appendingPathComponent(Self.directoryName, isDirectory: true) }

    /// The socket, falling back to `/tmp` when `$TMPDIR` would overflow `sun_path`.
    ///
    /// The fallback is a whole different directory rather than a shortened file name, because a
    /// truncated UDID is a socket two simulators could share.
    public func socket(udid: String) -> String {
        let preferred = socketPath(under: directory, udid: udid)
        guard preferred.count > Self.socketPathLimit else { return preferred }
        return socketPath(
            under: Self.fallbackBase.appendingPathComponent(
                Self.directoryName, isDirectory: true),
            udid: udid
        )
    }

    public func pidFile(udid: String) -> String { file(udid: udid, extension: "pid") }

    public func log(udid: String) -> String { file(udid: udid, extension: "log") }

    /// Creates the directory the socket will be bound in, `0700`.
    ///
    /// - Throws: `ProbeError.captureFailed` (exit 5) when it cannot be created.
    public func createDirectory(for udid: String) throws {
        let target = URL(fileURLWithPath: socket(udid: udid)).deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: target,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ProbeError.captureFailed(
                "could not create \(target.path): \(error.localizedDescription)")
        }
    }

    private func socketPath(under directory: URL, udid: String) -> String {
        directory.appendingPathComponent("\(udid).sock").path
    }

    private func file(udid: String, extension suffix: String) -> String {
        URL(fileURLWithPath: socket(udid: udid))
            .deletingPathExtension()
            .appendingPathExtension(suffix)
            .path
    }
}
