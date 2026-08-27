import Foundation

@testable import SimProbeCLI

/// Answers requests from a script instead of from a socket.
///
/// Records what it was asked, because most of what these verbs do is *ordering* — read a tree,
/// then tap what it named — and an order is only assertable if it was written down.
final class FakeDaemonClient: DaemonClient, @unchecked Sendable {

    private let responses: [DaemonOperation: DaemonResponse]
    private let failure: ProbeError?
    private let lock = NSLock()
    private var recorded: [DaemonRequest] = []

    init(responses: [DaemonOperation: DaemonResponse] = [:], failing failure: ProbeError? = nil) {
        self.responses = responses
        self.failure = failure
    }

    /// A client with nothing listening: every request fails the way the real one does.
    static func absent(udid: String = "UDID") -> FakeDaemonClient {
        FakeDaemonClient(failing: .daemonUnavailable(udid: udid))
    }

    var requests: [DaemonRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var operations: [DaemonOperation] { requests.map(\.op) }

    func send(_ request: DaemonRequest) throws -> DaemonResponse {
        lock.lock()
        recorded.append(request)
        lock.unlock()
        if let failure { throw failure }
        guard let response = responses[request.op] else {
            return DaemonResponse(ok: true, ms: 1.0)
        }
        return response
    }
}

/// A client that is absent until something spawns it, so `daemon start` can be asserted end to
/// end without a process or a socket.
final class SpawnableDaemonClient: DaemonClient, @unchecked Sendable {

    private let lock = NSLock()
    private var running = false
    private let treeJSON: String
    private let pid: Int32

    /// How many `ping`s must arrive before the daemon counts as up, modelling a start that is
    /// not instantaneous.
    private var pingsBeforeReady: Int

    /// How many further `ping`s answer `connecting: true`, modelling the window between the
    /// socket being bound and `idb connect` finishing.
    private var pingsWhileConnecting: Int

    init(
        treeJSON: String,
        pid: Int32 = 4_242,
        pingsBeforeReady: Int = 0,
        pingsWhileConnecting: Int = 0
    ) {
        self.treeJSON = treeJSON
        self.pid = pid
        self.pingsBeforeReady = pingsBeforeReady
        self.pingsWhileConnecting = pingsWhileConnecting
    }

    func markSpawned() {
        lock.lock()
        running = true
        lock.unlock()
    }

    var isUp: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running && pingsBeforeReady <= 0
    }

    func send(_ request: DaemonRequest) throws -> DaemonResponse {
        lock.lock()
        let up = running && pingsBeforeReady <= 0
        if running, pingsBeforeReady > 0 { pingsBeforeReady -= 1 }
        var connecting = false
        if up, pingsWhileConnecting > 0 {
            pingsWhileConnecting -= 1
            connecting = true
        }
        if request.op == .stop { running = false }
        lock.unlock()
        guard up else { throw ProbeError.daemonUnavailable(udid: "UDID") }
        switch request.op {
        case .ping:
            return DaemonResponse(
                ok: true,
                pid: pid,
                udid: "UDID",
                uptimeMs: 1_000,
                connecting: connecting ? true : nil
            )
        case .tree: return DaemonResponse(ok: true, ms: 70.0, treeJSON: treeJSON)
        case .tap, .stop: return DaemonResponse(ok: true, ms: 1.1)
        }
    }
}

/// Records a spawn instead of performing one.
final class FakeProcessSpawner: ProcessSpawning, @unchecked Sendable {

    private let lock = NSLock()
    private var recorded: [(executable: String, arguments: [String], logPath: String)] = []

    /// Run when a spawn is recorded, so a fake client can be told the daemon is now up.
    private let onSpawn: (@Sendable () -> Void)?

    /// Set to make spawning fail the way a missing binary does.
    private let failure: ProbeError?

    init(onSpawn: (@Sendable () -> Void)? = nil, failing failure: ProbeError? = nil) {
        self.onSpawn = onSpawn
        self.failure = failure
    }

    var spawns: [(executable: String, arguments: [String], logPath: String)] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func spawnDetached(_ executable: String, _ arguments: [String], logPath: String) throws
        -> Int32
    {
        if let failure { throw failure }
        lock.lock()
        recorded.append((executable, arguments, logPath))
        lock.unlock()
        onSpawn?()
        return 4_242
    }
}

/// Performs the two calls the daemon can make, from a script.
///
/// An `actor` rather than a lock-guarded class: `IdbActing` is an async protocol, and `NSLock`
/// is unavailable from an async context for exactly the reason it would be wrong here.
actor FakeIdbActor: IdbActing {

    struct Tap: Equatable {
        let x: Double
        let y: Double
    }

    private(set) var taps: [Tap] = []
    private let tree: String
    private let failure: ProbeError?

    init(treeJSON: String = "[]", failing failure: ProbeError? = nil) {
        tree = treeJSON
        self.failure = failure
    }

    func tap(x: Double, y: Double) async throws {
        if let failure { throw failure }
        taps.append(Tap(x: x, y: y))
    }

    func treeJSON() async throws -> String {
        if let failure { throw failure }
        return tree
    }
}

/// A recorded process that stays alive for a scripted number of checks.
///
/// The whole of `stop`'s new behaviour is a *wait*, and a wait is only assertable against
/// something that eventually stops being true on cue.
final class FakeProcessLiveness: ProcessLiveness, @unchecked Sendable {

    private let lock = NSLock()
    private var checksBeforeExit: Int
    private var terminated: [DaemonRecord] = []
    private var checks = 0

    /// - Parameter checksBeforeExit: how many `isRunning` calls answer `true`. `Int.max` models
    ///   a daemon that ignores the stop request entirely.
    init(checksBeforeExit: Int = 0) {
        self.checksBeforeExit = checksBeforeExit
    }

    var terminations: [DaemonRecord] {
        lock.lock()
        defer { lock.unlock() }
        return terminated
    }

    var checkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return checks
    }

    func isRunning(_ record: DaemonRecord) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        checks += 1
        guard checksBeforeExit > 0 else { return false }
        if checksBeforeExit != Int.max { checksBeforeExit -= 1 }
        return true
    }

    func terminate(_ record: DaemonRecord) {
        lock.lock()
        terminated.append(record)
        checksBeforeExit = 0
        lock.unlock()
    }
}

/// A ticker that only moves when a test moves it.
final class FakeTicker: MonotonicTicker, @unchecked Sendable {

    private let lock = NSLock()
    private var value: Int

    init(startMicroseconds: Int = 0) { value = startMicroseconds }

    var nowMicroseconds: Int {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        // Every reading advances by a fixed amount, so a measured call reports a stable,
        // non-zero duration without a test having to interleave advances by hand.
        value += 1_100
        return current
    }
}
