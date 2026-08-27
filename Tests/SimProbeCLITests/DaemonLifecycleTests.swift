import Foundation
import XCTest

@testable import SimProbeCLI

/// Starting, stopping and inspecting the daemon — asserted as a *sequence*, because that is
/// what the verbs actually are: spawn, poll, smoke-test, report.
final class DaemonLifecycleTests: XCTestCase {

    // MARK: - Paths

    func testSocketPidfileAndLogSitTogetherUnderOneDirectory() {
        let paths = DaemonPaths(base: URL(fileURLWithPath: "/var/tmp", isDirectory: true))

        XCTAssertEqual(paths.socket(udid: "ABC"), "/var/tmp/simprobe/ABC.sock")
        XCTAssertEqual(paths.pidFile(udid: "ABC"), "/var/tmp/simprobe/ABC.pid")
        XCTAssertEqual(paths.log(udid: "ABC"), "/var/tmp/simprobe/ABC.log")
    }

    /// A full-length identifier, assembled from its group lengths rather than written out.
    ///
    /// `scripts/hygiene-check.sh` rejects a canonical UDID anywhere in a tracked file, shape
    /// being all it has to go on, and it is right to: these tests are about the *length* of the
    /// path, so a placeholder of the same length is what they actually need.
    private static let fullLengthUdid = [8, 4, 4, 4, 12]
        .map { String(repeating: "A", count: $0) }
        .joined(separator: "-")

    /// `sun_path` is 104 bytes and a real `$TMPDIR` puts the socket at 100. A machine whose
    /// temporary directory is a little deeper must fall back rather than fail at `bind()` with
    /// an error naming neither the path nor its length.
    func testATooLongTemporaryDirectoryFallsBackToTmp() {
        let deep = URL(fileURLWithPath: "/var/folders/" + String(repeating: "x", count: 90))
        let paths = DaemonPaths(base: deep)

        let socket = paths.socket(udid: Self.fullLengthUdid)

        XCTAssertEqual(socket, "/tmp/simprobe/\(Self.fullLengthUdid).sock")
        XCTAssertLessThanOrEqual(socket.utf8.count, DaemonPaths.socketPathLimit)
    }

    /// The fallback keeps the whole UDID: a shortened name is a socket two simulators share.
    func testTheRealTemporaryDirectoryStillFits() {
        let socket = DaemonPaths.live().socket(udid: Self.fullLengthUdid)

        XCTAssertLessThanOrEqual(socket.utf8.count, DaemonPaths.socketPathLimit)
        XCTAssertTrue(socket.hasSuffix("\(Self.fullLengthUdid).sock"), socket)
    }

    // MARK: - Start

    func testStartSpawnsTheDaemonWithEveryPathItNeeds() throws {
        let context = Context()

        let report = try context.launcher().start(DaemonLaunchOptions(udid: "UDID"))

        let spawn = try XCTUnwrap(context.spawner.spawns.first)
        XCTAssertEqual(spawn.executable, Context.executable)
        XCTAssertEqual(
            spawn.arguments,
            [
                "--udid", "UDID",
                "--socket", context.paths.socket(udid: "UDID"),
                "--pid-file", context.paths.pidFile(udid: "UDID"),
                "--log", context.paths.log(udid: "UDID"),
                "--idle-timeout-ms", "\(DaemonLaunchOptions.defaultIdleTimeoutMs)",
            ]
        )
        XCTAssertEqual(spawn.logPath, context.paths.log(udid: "UDID"))
        XCTAssertFalse(report.wasAlreadyRunning)
        XCTAssertEqual(report.elementCount, 11)
    }

    /// The daemon does not answer the instant it is spawned; `start` must wait rather than
    /// declare failure on the first refused connection.
    func testStartWaitsForTheDaemonToAnswer() throws {
        let context = Context(pingsBeforeReady: 3)

        let report = try context.launcher().start(DaemonLaunchOptions(udid: "UDID"))

        XCTAssertGreaterThan(context.clock.sleeps.count, 0, "start never waited")
        XCTAssertEqual(report.elementCount, 11)
    }

    func testStartOnARunningDaemonReusesItInsteadOfSpawningASecond() throws {
        let context = Context()
        context.client.markSpawned()

        let report = try context.launcher().start(DaemonLaunchOptions(udid: "UDID"))

        XCTAssertTrue(context.spawner.spawns.isEmpty)
        XCTAssertTrue(report.wasAlreadyRunning)
    }

    func testStartGivesUpWhenTheDaemonNeverAnswers() {
        let context = Context(neverStarts: true)

        XCTAssertThrowsError(try context.launcher().start(DaemonLaunchOptions(udid: "UDID"))) {
            XCTAssertEqual(($0 as? ProbeError)?.exitCode, 2)
            // The log is where the reason is; the message has to say which file.
            XCTAssertTrue("\($0)".contains(".log"), "\($0)")
        }
    }

    /// Both halves of the smoke test have to pass. A tree is not proof that a screenshot works
    /// — the spike found idb's own screenshot breaking while its tree stayed fine.
    func testStartFailsWhenTheScreenshotFails() {
        let context = Context()
        context.capture.failure = .simctlFailed(command: "io screenshot", detail: "device busy")

        XCTAssertThrowsError(try context.launcher().start(DaemonLaunchOptions(udid: "UDID"))) {
            XCTAssertEqual(($0 as? ProbeError)?.exitCode, 2)
        }
    }

    func testStartFailsOnAnEmptyTree() {
        let context = Context(treeJSON: "[]")

        XCTAssertThrowsError(try context.launcher().start(DaemonLaunchOptions(udid: "UDID"))) {
            XCTAssertTrue("\($0)".contains("empty"), "\($0)")
        }
    }

    /// The daemon binds its socket before it reaches the companion, so an answered `ping` is
    /// not a usable daemon. Smoke-testing one that is still connecting is how `start` used to
    /// fail on a daemon that was about to work perfectly.
    func testStartWaitsForTheCompanionRatherThanForTheFirstAnswer() throws {
        let context = Context(pingsWhileConnecting: 3)

        let report = try context.launcher().start(DaemonLaunchOptions(udid: "UDID"))

        XCTAssertGreaterThanOrEqual(context.clock.sleeps.count, 3, "start never waited")
        XCTAssertEqual(report.elementCount, 11)
    }

    /// A daemon somebody else started a second ago is in that same half-built state, and the
    /// reuse path has to wait for it too.
    func testStartWaitsForAReusedDaemonThatIsStillConnecting() throws {
        let context = Context(pingsWhileConnecting: 2)
        context.client.markSpawned()

        let report = try context.launcher().start(DaemonLaunchOptions(udid: "UDID"))

        XCTAssertTrue(report.wasAlreadyRunning)
        XCTAssertTrue(context.spawner.spawns.isEmpty)
        XCTAssertGreaterThanOrEqual(context.clock.sleeps.count, 1, "reuse never waited")
    }

    // MARK: - Stop and status

    func testStopAsksTheDaemonToExit() throws {
        let context = Context()
        context.client.markSpawned()

        XCTAssertTrue(try context.launcher().stop(udid: "UDID"))
        XCTAssertFalse(context.client.isUp)
    }

    /// `stop` returning while the process is still alive is what let a `stop; start` pair race:
    /// the old daemon still owned the socket the new one was unlinking.
    func testStopWaitsForTheProcessToActuallyGo() throws {
        let context = Context(checksBeforeExit: 3)
        context.client.markSpawned()
        let pidFile = try context.writePidFile()

        XCTAssertTrue(try context.launcher().stop(udid: "UDID"))

        XCTAssertGreaterThanOrEqual(context.liveness.checkCount, 3, "stop never waited")
        XCTAssertTrue(context.liveness.terminations.isEmpty, "a daemon that left needs no signal")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile))
    }

    /// A daemon that ignores the request is signalled — but only at the deadline, and only
    /// after the wait, and the pidfile survives until it is actually gone.
    func testStopInsistsWithASignalAtTheDeadline() throws {
        let context = Context(checksBeforeExit: Int.max)
        context.client.markSpawned()
        _ = try context.writePidFile()

        XCTAssertTrue(try context.launcher().stop(udid: "UDID"))

        XCTAssertEqual(context.liveness.terminations.map(\.pid), [4_242])
        XCTAssertGreaterThanOrEqual(
            context.clock.sleeps.count,
            DaemonLauncher.stopTimeoutMs / DaemonLaunchOptions.readyPollIntervalMs - 1
        )
    }

    /// The socket is gone but the process is not: the pidfile is the only handle left, and it
    /// is removed after the signal has been confirmed to have worked, never before.
    func testStopFallsBackToThePidfileAndRemovesItLast() throws {
        let context = Context(checksBeforeExit: 1)
        let pidFile = try context.writePidFile()

        XCTAssertTrue(try context.launcher().stop(udid: "UDID"))

        XCTAssertEqual(context.liveness.terminations.map(\.pid), [4_242])
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile))
    }

    func testStopWithNothingRunningIsNotAnError() throws {
        let context = Context()

        XCTAssertFalse(try context.launcher().stop(udid: "UDID"))
    }

    /// A pidfile left by a crash names a number the system has since handed to something else.
    /// Signalling it blind is how a tool acquires a reputation for killing unrelated processes.
    func testAStalePidfileIsDiscardedRatherThanSignalled() throws {
        let context = Context()
        try context.paths.createDirectory(for: "UDID")
        let pidFile = context.paths.pidFile(udid: "UDID")
        try DaemonRecord(pid: 999_999, udid: "UDID", executable: "/nonexistent/simprobe-daemon")
            .write(to: pidFile)

        XCTAssertFalse(try context.launcher().stop(udid: "UDID"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile))
    }

    func testAPidfileRoundTrips() throws {
        let context = Context()
        try context.paths.createDirectory(for: "UDID")
        let path = context.paths.pidFile(udid: "UDID")
        let record = DaemonRecord(pid: 4_242, udid: "UDID", executable: Context.executable)

        try record.write(to: path)

        XCTAssertEqual(DaemonRecord.read(from: path), record)
        XCTAssertNil(DaemonRecord.read(from: path + ".missing"))
    }

    func testStatusReportsPidAndUptimeWhenRunning() throws {
        let context = Context()
        context.client.markSpawned()
        let output = RecordingOutput()

        let code = try DaemonRunner(launcher: context.launcher())
            .status(udid: "UDID", json: false, to: output)

        XCTAssertEqual(code, 0)
        XCTAssertEqual(output.out, "running (UDID, pid 4242, up 1s)")
    }

    /// Absence is a result, not an error: a caller scripting `status` branches on the text.
    func testStatusExitsZeroWhenNothingIsRunning() throws {
        let output = RecordingOutput()

        let code = try DaemonRunner(launcher: Context().launcher())
            .status(udid: "UDID", json: false, to: output)

        XCTAssertEqual(code, 0)
        XCTAssertEqual(output.out, "not running (UDID)")
    }

    func testStatusJSONCarriesTheRunningFlag() throws {
        let output = RecordingOutput()

        _ = try DaemonRunner(launcher: Context().launcher())
            .status(udid: "UDID", json: true, to: output)

        XCTAssertEqual(output.out, #"{"running":false,"udid":"UDID"}"#)
    }

    // MARK: - Reporting

    func testStartPrintsTheElementCountAndTheTimeItTook() throws {
        let context = Context()
        let output = RecordingOutput()

        _ = try DaemonRunner(launcher: context.launcher())
            .start(DaemonLaunchOptions(udid: "UDID"), to: output)

        XCTAssertEqual(output.out, "daemon ready (UDID, tree 11 elements, 0 ms)")
    }

    func testStartSaysWhenItReusedARunningDaemon() throws {
        let context = Context()
        context.client.markSpawned()
        let output = RecordingOutput()

        _ = try DaemonRunner(launcher: context.launcher())
            .start(DaemonLaunchOptions(udid: "UDID"), to: output)

        XCTAssertTrue(output.out.hasSuffix("already running)"), output.out)
    }

    func testStopReportsBothOutcomes() throws {
        let context = Context()
        let stopped = RecordingOutput()
        let absent = RecordingOutput()
        context.client.markSpawned()

        _ = try DaemonRunner(launcher: context.launcher())
            .stop(udid: "UDID", json: false, to: stopped)
        _ = try DaemonRunner(launcher: context.launcher())
            .stop(udid: "UDID", json: false, to: absent)

        XCTAssertEqual(stopped.out, "daemon stopped (UDID)")
        XCTAssertEqual(absent.out, "no daemon running (UDID)")
    }

    func testUptimeReadsAsADuration() {
        XCTAssertEqual(DaemonRunner.duration(ms: 0), "0s")
        XCTAssertEqual(DaemonRunner.duration(ms: 45_000), "45s")
        XCTAssertEqual(DaemonRunner.duration(ms: 192_000), "3m12s")
        XCTAssertEqual(DaemonRunner.duration(ms: 7_440_000), "2h04m")
    }

    // MARK: - Harness

    /// One daemon's worth of fakes, in a temporary directory of its own.
    private final class Context {

        static let executable = "/opt/homebrew/bin/simprobe-daemon"

        let paths: DaemonPaths
        let client: SpawnableDaemonClient
        let spawner: FakeProcessSpawner
        let clock = VirtualClock()
        let liveness: FakeProcessLiveness
        /// One mid-grey frame: the smoke test only ever asks whether a capture *worked*.
        let capture = ScriptedCapture(
            frames: (try? TestFrames.uniform(width: 8, height: 8, luminance: 128)).map { [$0] }
                ?? [])

        init(
            treeJSON: String = ElementFixture.describeAll,
            pingsBeforeReady: Int = 0,
            pingsWhileConnecting: Int = 0,
            neverStarts: Bool = false,
            checksBeforeExit: Int = 0
        ) {
            liveness = FakeProcessLiveness(checksBeforeExit: checksBeforeExit)
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("simprobe-tests-\(UUID().uuidString)", isDirectory: true)
            paths = DaemonPaths(base: base)
            let client = SpawnableDaemonClient(
                treeJSON: treeJSON,
                pingsBeforeReady: pingsBeforeReady,
                pingsWhileConnecting: pingsWhileConnecting
            )
            self.client = client
            let markSpawned: @Sendable () -> Void = { client.markSpawned() }
            let onSpawn: (@Sendable () -> Void)? = neverStarts ? nil : markSpawned
            spawner = FakeProcessSpawner(onSpawn: onSpawn)
        }

        deinit {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: paths.socket(udid: "UDID"))
                    .deletingLastPathComponent())
        }

        func launcher() -> DaemonLauncher {
            DaemonLauncher(
                paths: paths,
                client: client,
                spawner: spawner,
                clock: clock,
                capture: capture,
                executable: Self.executable,
                liveness: liveness
            )
        }

        /// The pidfile a running daemon would have left, which is what `stop` waits on.
        @discardableResult
        func writePidFile() throws -> String {
            try paths.createDirectory(for: "UDID")
            let path = paths.pidFile(udid: "UDID")
            try DaemonRecord(pid: 4_242, udid: "UDID", executable: Self.executable).write(to: path)
            return path
        }
    }
}
