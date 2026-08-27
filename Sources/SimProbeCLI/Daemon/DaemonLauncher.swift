import Darwin
import Foundation

/// What `daemon start` was asked for.
public struct DaemonLaunchOptions: Equatable, Sendable {

    /// How long a daemon sits idle before exiting. Ten minutes: long enough to span a slow
    /// agent turn, short enough that a forgotten daemon is not still holding a gRPC channel to
    /// a simulator that was shut down hours ago.
    public static let defaultIdleTimeoutMs = 10 * 60 * 1_000

    /// How long `start` waits for the new daemon to answer a ping. The first connection after a
    /// boot goes through `idb connect`, which on a cold companion costs several seconds.
    public static let defaultReadyTimeoutMs = 30_000

    /// How often the readiness poll asks. Fast enough that a warm start still prints in well
    /// under a second.
    public static let readyPollIntervalMs = 50

    public let udid: String
    public let idleTimeoutMs: Int
    public let readyTimeoutMs: Int
    public let json: Bool

    public init(
        udid: String,
        idleTimeoutMs: Int = defaultIdleTimeoutMs,
        readyTimeoutMs: Int = defaultReadyTimeoutMs,
        json: Bool = false
    ) {
        self.udid = udid
        self.idleTimeoutMs = idleTimeoutMs
        self.readyTimeoutMs = readyTimeoutMs
        self.json = json
    }
}

/// What `daemon start` found out.
public struct DaemonStartReport: Equatable, Sendable {

    public let udid: String
    public let elementCount: Int

    /// Wall time from the decision to start to a passing smoke test.
    public let ms: Int
    public let wasAlreadyRunning: Bool

    public init(udid: String, elementCount: Int, ms: Int, wasAlreadyRunning: Bool) {
        self.udid = udid
        self.elementCount = elementCount
        self.ms = ms
        self.wasAlreadyRunning = wasAlreadyRunning
    }
}

/// What `daemon status` found.
public struct DaemonStatus: Equatable, Sendable {

    public let udid: String
    public let pid: Int32?
    public let uptimeMs: Int?

    public var isRunning: Bool { pid != nil }

    public init(udid: String, pid: Int32? = nil, uptimeMs: Int? = nil) {
        self.udid = udid
        self.pid = pid
        self.uptimeMs = uptimeMs
    }
}

/// Starts, stops and inspects the daemon for one simulator.
///
/// Every collaborator is injected, including the thing that spawns processes and the thing that
/// takes screenshots, because the interesting behaviour here is a *sequence* — spawn, poll,
/// smoke-test, report — and a sequence is only worth having if it can be asserted.
public struct DaemonLauncher {

    private let paths: DaemonPaths
    private let client: any DaemonClient
    private let spawner: any ProcessSpawning
    private let clock: any ProbeClock
    private let capture: any ScreenCapturing
    private let executable: String
    private let liveness: any ProcessLiveness

    /// How long `stop` waits for the daemon to actually exit before insisting with `SIGTERM`.
    ///
    /// Five seconds: a daemon mid-`accessibility_info` finishes the call before it notices the
    /// stop, and a client that returns while the old process still holds the socket is exactly
    /// the race that makes the next `start` fail on an address already in use.
    public static let stopTimeoutMs = 5_000

    public init(
        paths: DaemonPaths,
        client: any DaemonClient,
        spawner: any ProcessSpawning,
        clock: any ProbeClock,
        capture: any ScreenCapturing,
        executable: String,
        liveness: any ProcessLiveness = SystemProcessLiveness()
    ) {
        self.paths = paths
        self.client = client
        self.spawner = spawner
        self.clock = clock
        self.capture = capture
        self.executable = executable
        self.liveness = liveness
    }

    /// Spawns a daemon if none is listening, waits for it, and smoke-tests it.
    ///
    /// - Throws: `ProbeError.idbFailed` (exit 2) when it never answers or the smoke test fails.
    public func start(_ options: DaemonLaunchOptions) throws -> DaemonStartReport {
        let began = clock.nowMs
        try paths.createDirectory(for: options.udid)
        let alreadyRunning = client.isRunning
        if !alreadyRunning {
            _ = try spawner.spawnDetached(
                executable,
                [
                    "--udid", options.udid,
                    "--socket", paths.socket(udid: options.udid),
                    "--pid-file", paths.pidFile(udid: options.udid),
                    "--log", paths.log(udid: options.udid),
                    "--idle-timeout-ms", "\(options.idleTimeoutMs)",
                ],
                logPath: paths.log(udid: options.udid)
            )
        }
        // Waited for in both branches. A daemon binds its socket before it reaches the
        // companion, so an answered `ping` means "there is a process", not "there is a warm
        // channel" — and a daemon someone else started a second ago is in exactly that state.
        try waitUntilReady(options)
        let elements = try smokeTest(udid: options.udid)
        return DaemonStartReport(
            udid: options.udid,
            elementCount: elements,
            ms: clock.nowMs - began,
            wasAlreadyRunning: alreadyRunning
        )
    }

    /// Asks the daemon to exit, waits for it to actually go, and falls back to its pidfile.
    ///
    /// `stop` returning while the process is still alive is what made `stop; start` fail: the
    /// old daemon still owned the socket, and the new one unlinked and rebound it underneath
    /// its own successor. So the answer to the `stop` request is only the beginning — what
    /// makes this true is the pid being gone.
    ///
    /// The pidfile is removed **last**, after the process is confirmed gone, because until then
    /// it is the only handle anyone has on a daemon that did not listen.
    ///
    /// - Returns: whether anything was running to stop.
    public func stop(udid: String) throws -> Bool {
        let record = DaemonRecord.read(from: paths.pidFile(udid: udid))
        if client.isRunning {
            _ = try? client.send(.stop)
            record.map(waitForExit)
            removePidFile(udid: udid)
            return true
        }
        guard let record else { return false }
        // The only process simprobe ever signals: one its own daemon wrote down, still running,
        // still the same executable, and still named `simprobe-daemon`. A recycled pid fails
        // this and is left alone.
        guard liveness.isRunning(record) else {
            removePidFile(udid: udid)
            return false
        }
        liveness.terminate(record)
        waitForExit(record)
        removePidFile(udid: udid)
        return true
    }

    /// Polls until the recorded process is gone, insisting with `SIGTERM` at the deadline.
    private func waitForExit(_ record: DaemonRecord) {
        let deadline = clock.nowMs + Self.stopTimeoutMs
        while clock.nowMs < deadline {
            guard liveness.isRunning(record) else { return }
            clock.sleep(ms: DaemonLaunchOptions.readyPollIntervalMs)
        }
        liveness.terminate(record)
    }

    public func status(udid: String) -> DaemonStatus {
        guard let response = try? client.send(.ping), response.ok else {
            return DaemonStatus(udid: udid)
        }
        return DaemonStatus(udid: udid, pid: response.pid, uptimeMs: response.uptimeMs)
    }

    // MARK: Start helpers

    private func waitUntilReady(_ options: DaemonLaunchOptions) throws {
        let deadline = clock.nowMs + options.readyTimeoutMs
        while clock.nowMs < deadline {
            if client.isReady { return }
            clock.sleep(ms: DaemonLaunchOptions.readyPollIntervalMs)
        }
        throw ProbeError.idbFailed(
            command: "daemon start",
            detail: "no answer after \(options.readyTimeoutMs)ms; "
                + "see \(paths.log(udid: options.udid))"
        )
    }

    /// Proves the daemon can do both halves of the job before saying it is ready.
    ///
    /// The screenshot half goes through `simctl`, not idb: the spike found idb's screenshot
    /// breaks once the companion outlives a simulator reboot, and reconnecting does not heal it.
    /// Capture stays on `simctl` everywhere, so this checks the path a caller will actually use
    /// rather than one that is merely adjacent to it.
    ///
    /// - Returns: how many elements the tree carried.
    private func smokeTest(udid: String) throws -> Int {
        let snapshot = try DaemonElementDescriber(client: client).describeAll(udid: udid)
        guard !snapshot.elements.isEmpty else {
            throw ProbeError.idbFailed(
                command: "daemon start",
                detail: "the tree came back empty; is anything running on the simulator?"
            )
        }
        _ = try capture.capture(udid: udid, deadlineMs: ProcessDeadline.defaultMs)
        return snapshot.elements.count
    }

    private func removePidFile(udid: String) {
        try? FileManager.default.removeItem(atPath: paths.pidFile(udid: udid))
    }
}
