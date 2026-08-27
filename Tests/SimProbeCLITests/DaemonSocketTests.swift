import Darwin
import Foundation
import XCTest

@testable import SimProbeCLI

/// The socket client against a **real** `AF_UNIX` socket.
///
/// No simulator and no gRPC are involved: the server here is twenty lines of `bind`/`accept` in
/// this test file. That is deliberate — framing, partial reads, a peer that hangs up and a
/// socket that is simply not there are exactly the things a fake client cannot prove, and they
/// are the things that break in the field.
final class DaemonSocketTests: XCTestCase {

    func testARequestGetsItsResponse() throws {
        let server = try TestSocketServer(path: path()) { line in
            XCTAssertEqual(line.trimmingCharacters(in: .newlines), #"{"op":"ping"}"#)
            return #"{"ok":true,"pid":4242,"udid":"UDID","uptimeMs":1000}"#
        }
        defer { server.stop() }

        let response = try client(server.path).send(.ping)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.pid, 4_242)
        XCTAssertEqual(response.uptimeMs, 1_000)
    }

    /// A whole accessibility tree is bigger than one read buffer, so the client must keep
    /// reading until the frame terminator rather than parsing the first chunk it gets.
    func testAResponseLargerThanOneReadIsReassembled() throws {
        let payload = String(repeating: "x", count: 200_000)
        let server = try TestSocketServer(path: path()) { _ in
            (try? DaemonProtocol.encode(DaemonResponse(ok: true, treeJSON: payload))) ?? ""
        }
        defer { server.stop() }

        let response = try client(server.path).send(.tree)

        XCTAssertEqual(response.treeJSON?.count, payload.count)
    }

    func testNothingListeningIsReportedAsAMissingDaemon() {
        let absent = client(path())

        XCTAssertThrowsError(try absent.send(.ping)) { error in
            XCTAssertEqual(error as? ProbeError, .daemonUnavailable(udid: "UDID"))
        }
        XCTAssertFalse(absent.isRunning)
    }

    /// A socket file left behind by a crashed daemon is not a daemon, and connecting to it fails
    /// the same way an absent one does — which is what makes `daemon start` able to replace it.
    func testAStaleSocketFileIsNotADaemon() throws {
        let stale = path()
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: stale).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: stale, contents: Data())

        XCTAssertFalse(client(stale).isRunning)
    }

    func testAPeerThatHangsUpWithoutAnsweringIsAnEnvironmentFailure() throws {
        let server = try TestSocketServer(path: path()) { _ in nil }
        defer { server.stop() }

        XCTAssertThrowsError(try client(server.path).send(.tree)) { error in
            XCTAssertEqual((error as? ProbeError)?.exitCode, 2)
            XCTAssertTrue("\(error)".contains("without answering"), "\(error)")
        }
    }

    func testAnUnreadableResponseIsReportedRatherThanGuessed() throws {
        let server = try TestSocketServer(path: path()) { _ in "this is not json" }
        defer { server.stop() }

        XCTAssertThrowsError(try client(server.path).send(.ping)) { error in
            XCTAssertEqual((error as? ProbeError)?.exitCode, 2)
        }
    }

    func testIsRunningIsTrueOnlyWhenSomethingAnswers() throws {
        let server = try TestSocketServer(path: path()) { _ in #"{"ok":true}"# }
        defer { server.stop() }

        XCTAssertTrue(client(server.path).isRunning)
    }

    /// The client refuses a path it could not bind rather than silently truncating it, because a
    /// truncated socket path is a socket some other simulator answers on.
    func testAnOverlongPathIsRejected() {
        let overlong = "/tmp/" + String(repeating: "x", count: 120) + ".sock"

        XCTAssertThrowsError(
            try UnixSocketDaemonClient(path: overlong, udid: "UDID").send(.ping)
        ) { error in
            XCTAssertEqual((error as? ProbeError)?.exitCode, 5)
        }
    }

    // MARK: - Spawning

    func testTheSpawnerStartsAProcessAndAppendsToItsLog() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("simprobe-spawn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let logPath = directory.appendingPathComponent("daemon.log").path

        let pid = try DetachedProcessSpawner()
            .spawnDetached("/bin/echo", ["started"], logPath: logPath)

        XCTAssertGreaterThan(pid, 0)
        // The spawner deliberately does not wait for the child, so the test does.
        let deadline = Date().addingTimeInterval(5)
        var written = ""
        while Date() < deadline, !written.contains("started") {
            written = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
            if written.isEmpty { Thread.sleep(forTimeInterval: 0.02) }
        }
        XCTAssertEqual(written, "started\n")
    }

    /// The log is opened before the child is started, so this has to fail on the binary rather
    /// than on the log — which is why it is given a real one.
    func testSpawningSomethingThatIsNotThereFails() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("simprobe-spawn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(
            try DetachedProcessSpawner().spawnDetached(
                "/nonexistent/simprobe-daemon",
                [],
                logPath: directory.appendingPathComponent("daemon.log").path
            )
        ) { error in
            XCTAssertEqual((error as? ProbeError)?.exitCode, 5)
            XCTAssertTrue("\(error)".contains("/nonexistent/simprobe-daemon"), "\(error)")
        }
    }

    /// Under the test runner there is no `simprobe-daemon` beside the executable, so this is the
    /// message a user gets from a half-installed pair of binaries.
    func testTheDaemonBinaryIsLookedForBesideTheCLI() {
        XCTAssertThrowsError(try DaemonExecutable.locate()) { error in
            XCTAssertEqual((error as? ProbeError)?.exitCode, 2)
            XCTAssertTrue("\(error)".contains("simprobe-daemon"), "\(error)")
        }
    }

    func testASessionWiresTheSocketPathToTheClient() {
        let session = DaemonSession(
            udid: "UDID", paths: DaemonPaths(base: URL(fileURLWithPath: "/var/tmp")))

        XCTAssertEqual(session.udid, "UDID")
        XCTAssertEqual(session.paths.socket(udid: "UDID"), "/var/tmp/simprobe/UDID.sock")
        XCTAssertFalse(session.client.isRunning)
    }

    /// A short base on purpose: under a real `$TMPDIR` plus a full-length UDID the path would
    /// exceed `sun_path` and land in the `/tmp` fallback, which is a different test.
    func testTheDirectoryIsCreatedPrivateToItsOwner() throws {
        let base = URL(
            fileURLWithPath: "/var/tmp/sp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let paths = DaemonPaths(base: base)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }

        try paths.createDirectory(for: "UDID")

        let attributes = try FileManager.default.attributesOfItem(atPath: paths.directory.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o700)
    }

    // MARK: - Harness

    private func path() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sp-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathComponent("d.sock")
            .path
    }

    private func client(_ path: String) -> UnixSocketDaemonClient {
        // Short next to the 30 s default: every server here answers immediately or not at all,
        // and a test that waits half a minute to fail is a test nobody runs.
        UnixSocketDaemonClient(path: path, udid: "UDID", timeoutMs: 3_000)
    }
}

/// A one-connection-at-a-time `AF_UNIX` server, for testing the client against a real socket.
///
/// `@unchecked Sendable`: the accept loop owns everything after `init`, and `stop()` only flips
/// one atomic-enough flag and closes the listening descriptor to wake it.
private final class TestSocketServer: @unchecked Sendable {

    let path: String
    private let descriptor: Int32
    private let thread: Thread

    /// - Parameter respond: the line to answer with, or `nil` to hang up without answering.
    init(path: String, respond: @escaping @Sendable (String) -> String?) throws {
        self.path = path
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // A local rather than the property throughout: the thread closure below may not touch
        // `self` until every member is initialised, and it is initialised by that very line.
        let listening = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listening, $0, size) }
        }
        guard bound == 0, listen(listening, 4) == 0 else {
            close(listening)
            throw ProbeError.captureFailed("could not bind the test socket at \(path)")
        }
        descriptor = listening
        thread = Thread {
            while true {
                let connection = accept(listening, nil, nil)
                guard connection >= 0 else { return }
                var buffer = [UInt8](repeating: 0, count: 4_096)
                let count = read(connection, &buffer, buffer.count)
                let line = count > 0 ? String(decoding: buffer[0..<count], as: UTF8.self) : ""
                if let answer = respond(line) {
                    _ = (answer + "\n").withCString { write(connection, $0, strlen($0)) }
                }
                close(connection)
            }
        }
        thread.start()
    }

    func stop() {
        close(descriptor)
        unlink(path)
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: path).deletingLastPathComponent())
    }
}
