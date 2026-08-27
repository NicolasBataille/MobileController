import Foundation

/// Finding the `simprobe-daemon` binary that goes with *this* `simprobe`.
///
/// A sibling of the running executable, never a PATH lookup: the two products are built and
/// installed together — `bin/simprobe` and `bin/simprobe-daemon` under Homebrew,
/// `.build/debug/` from a checkout — and a PATH lookup could pair a fresh CLI with a stale
/// daemon whose wire protocol has moved on.
public enum DaemonExecutable {

    public static let name = "simprobe-daemon"

    public static let installHint =
        "build it with: swift build -c release --product \(name), or reinstall simprobe"

    /// - Throws: `ProbeError.dependencyMissing` (exit 2) when there is no daemon beside the CLI.
    public static func locate() throws -> String {
        let ownPath =
            ProcessIdentity.executablePath(of: ProcessInfo.processInfo.processIdentifier)
            ?? CommandLine.arguments.first
        guard let ownPath else {
            throw ProbeError.dependencyMissing(tool: name, hint: installHint)
        }
        let candidate = URL(fileURLWithPath: ownPath)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent(name)
            .path
        guard FileManager.default.isExecutableFile(atPath: candidate) else {
            throw ProbeError.dependencyMissing(tool: name, hint: installHint)
        }
        return candidate
    }
}

/// Everything the daemon verbs need from the outside world, assembled once.
public struct DaemonSession {

    public let udid: String
    public let paths: DaemonPaths
    public let client: any DaemonClient

    public init(udid: String, paths: DaemonPaths = .live()) {
        self.udid = udid
        self.paths = paths
        client = UnixSocketDaemonClient(path: paths.socket(udid: udid), udid: udid)
    }

    /// The live launcher: real spawning, a real clock, and `simctl` for the smoke test's
    /// screenshot — the same capture every other verb uses.
    public func launcher(simctl: String) throws -> DaemonLauncher {
        DaemonLauncher(
            paths: paths,
            client: client,
            spawner: DetachedProcessSpawner(),
            clock: SystemClock(),
            capture: SimctlScreenCapture(simctl: simctl),
            executable: try DaemonExecutable.locate()
        )
    }

    public var describer: DaemonElementDescriber { DaemonElementDescriber(client: client) }
}
