import Darwin
import Foundation
import XCTest

@testable import SimProbeCLI

/// The parts of the daemon that only ever run when something has gone wrong.
///
/// A timed-out read, a 64 KB request, a symlink where a log file should be, a pidfile that
/// belongs to the daemon that replaced us. None of it happens on a good day, all of it is
/// unreachable from a live test, and every one of them is a way the daemon damages something
/// outside itself — so the coverage has to come from here.
final class DaemonHardeningTests: XCTestCase {

    // MARK: - Syscall outcomes

    /// The whole reason this is a type: `read` returning `-1` means four different things, and
    /// three of them are not "the peer hung up".
    func testASyscallResultIsClassifiedByItsErrno() {
        XCTAssertEqual(SocketIO.classify(count: 12, errno: 0), .bytes(12))
        XCTAssertEqual(SocketIO.classify(count: 0, errno: 0), .closed)
        XCTAssertEqual(SocketIO.classify(count: -1, errno: EINTR), .interrupted)
        XCTAssertEqual(SocketIO.classify(count: -1, errno: EAGAIN), .timedOut)
        XCTAssertEqual(SocketIO.classify(count: -1, errno: EWOULDBLOCK), .timedOut)
        XCTAssertEqual(SocketIO.classify(count: -1, errno: ECONNRESET), .failed(ECONNRESET))
    }

    /// A wedged daemon and a daemon that hung up are two different bugs, and the message has to
    /// say which one happened — including how long it was given.
    func testATimeoutIsNotAClosedConnection() {
        XCTAssertNotEqual(SocketIO.classify(count: -1, errno: EAGAIN), .closed)
        XCTAssertEqual(
            "\(UnixSocketDaemonClient.timedOut(3_000, half: "answer"))",
            "idb daemon failed: the daemon timed out after 3000 ms on answer"
        )
    }

    // MARK: - Framing

    func testALineIsCompleteAtTheFirstTerminatorAndCarriesNoneOfIt() {
        var accumulator = LineAccumulator()

        XCTAssertEqual(accumulator.append(Array(#"{"op":"pi"#.utf8)), .needsMore)
        XCTAssertEqual(accumulator.append(Array("ng\"}\n".utf8)), .complete(#"{"op":"ping"}"#))
    }

    func testAnEmptyAccumulatorKnowsNothingArrived() {
        var accumulator = LineAccumulator()

        XCTAssertTrue(accumulator.isEmpty)
        XCTAssertEqual(accumulator.append(Array("x".utf8)), .needsMore)
        XCTAssertFalse(accumulator.isEmpty)
        XCTAssertEqual(accumulator.text, "x")
    }

    /// A peer that never sends a terminator is a peer that would otherwise grow the daemon's
    /// memory until something else on the machine dies.
    func testAnUnterminatedRequestStopsAtTheCap() {
        var accumulator = LineAccumulator(limit: 64)

        XCTAssertEqual(accumulator.append([UInt8](repeating: 0x78, count: 63)), .needsMore)
        XCTAssertEqual(accumulator.append([0x78]), .overflow)
    }

    func testTheCapIsSixtyFourKilobytes() {
        XCTAssertEqual(SocketIO.maxRequestBytes, 65_536)
        // Well under the client's own 30 s budget, so a stalled connection is dropped by the
        // daemon rather than by the caller.
        XCTAssertLessThan(SocketIO.connectionTimeoutMs, UnixSocketDaemonClient.defaultTimeoutMs)
    }

    // MARK: - Directory ownership

    func testAPermissiveDirectoryWeOwnIsRepairedRatherThanRefused() throws {
        let directory = try makeDirectory(mode: 0o777)

        try SecureFile.requirePrivateDirectory(atPath: directory.path)

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o700)
    }

    /// The check is on the node, not on the path: a symlink pointing at a directory somebody
    /// else can write to passes every check made through `stat` and fails this one.
    func testASymlinkIsNotADirectoryThisDaemonWillUse() throws {
        let directory = try makeDirectory(mode: 0o700)
        let link = directory.deletingLastPathComponent()
            .appendingPathComponent("sp-link-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: link) }

        XCTAssertThrowsError(try SecureFile.requirePrivateDirectory(atPath: link.path)) { error in
            XCTAssertEqual((error as? ProbeError)?.exitCode, 5)
            XCTAssertTrue("\(error)".contains(link.path), "\(error)")
        }
    }

    func testAFileWhereTheDirectoryShouldBeIsRefused() throws {
        let directory = try makeDirectory(mode: 0o700)
        let file = directory.appendingPathComponent("not-a-directory")
        FileManager.default.createFile(atPath: file.path, contents: Data())

        XCTAssertThrowsError(try SecureFile.requirePrivateDirectory(atPath: file.path)) { error in
            XCTAssertTrue("\(error)".contains("not a directory"), "\(error)")
        }
        XCTAssertThrowsError(
            try SecureFile.requirePrivateDirectory(atPath: file.path + ".missing"))
    }

    /// `DaemonPaths` is where this actually bites: the directory is created and then proved.
    func testCreatingTheDaemonDirectoryRepairsAPermissiveOne() throws {
        let base = try makeDirectory(mode: 0o700)
        let paths = DaemonPaths(base: base)
        try FileManager.default.createDirectory(
            at: paths.directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o777]
        )

        try paths.createDirectory(for: "UDID")

        let attributes = try FileManager.default.attributesOfItem(atPath: paths.directory.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o700)
    }

    func testCreatingTheDaemonDirectoryRefusesASymlinkedOne() throws {
        let base = try makeDirectory(mode: 0o700)
        let elsewhere = try makeDirectory(mode: 0o777)
        let paths = DaemonPaths(base: base)
        try FileManager.default.createSymbolicLink(
            at: paths.directory, withDestinationURL: elsewhere)

        XCTAssertThrowsError(try paths.createDirectory(for: "UDID")) { error in
            XCTAssertEqual((error as? ProbeError)?.exitCode, 5)
        }
    }

    // MARK: - Files

    func testAppendingOpensCreatesAndKeepsTheFilePrivate() throws {
        let directory = try makeDirectory(mode: 0o700)
        let path = directory.appendingPathComponent("daemon.log").path

        let descriptor = try SecureFile.openForAppending(atPath: path)
        XCTAssertEqual(write(descriptor, "one\n", 4), 4)
        close(descriptor)
        let second = try SecureFile.openForAppending(atPath: path)
        XCTAssertEqual(write(second, "two\n", 4), 4)
        close(second)

        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "one\ntwo\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    /// The attack this exists for: a symlink planted at the log path turns every daemon write
    /// into an append aimed at whatever the link names.
    func testAppendingRefusesToFollowASymlink() throws {
        let directory = try makeDirectory(mode: 0o700)
        let target = directory.appendingPathComponent("victim")
        FileManager.default.createFile(atPath: target.path, contents: Data())
        let link = directory.appendingPathComponent("daemon.log")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try SecureFile.openForAppending(atPath: link.path)) { error in
            XCTAssertEqual((error as? ProbeError)?.exitCode, 5)
            XCTAssertTrue("\(error)".contains(link.path), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: target), Data())
    }

    func testAppendingRefusesSomethingThatIsNotARegularFile() {
        XCTAssertThrowsError(try SecureFile.openForAppending(atPath: "/dev/null")) { error in
            XCTAssertTrue("\(error)".contains("regular file"), "\(error)")
        }
    }

    // MARK: - Unlinking

    func testOnlyTheNodeWeBoundIsUnlinked() throws {
        let directory = try makeDirectory(mode: 0o700)
        let path = directory.appendingPathComponent("d.sock").path
        FileManager.default.createFile(atPath: path, contents: Data())
        let identity = try XCTUnwrap(SecureFile.identity(ofPath: path))

        // The node at that path is replaced — which is what happens when a daemon exits slowly
        // and its successor has already unlinked and rebound the socket.
        try FileManager.default.removeItem(atPath: path)
        FileManager.default.createFile(atPath: path, contents: Data("someone else".utf8))

        XCTAssertFalse(SecureFile.unlink(path: path, matching: identity))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(SecureFile.unlink(path: path, matching: SecureFile.identity(ofPath: path)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(SecureFile.unlink(path: path, matching: nil))
    }

    func testOnlyASocketWeOwnCountsAsOneToReplace() throws {
        let directory = try makeDirectory(mode: 0o700)
        let regular = directory.appendingPathComponent("regular").path
        FileManager.default.createFile(atPath: regular, contents: Data())
        let socketPath = directory.appendingPathComponent("d.sock").path
        let bound = try bindSocket(at: socketPath)
        defer { close(bound) }

        XCTAssertTrue(SecureFile.isOwnedSocket(atPath: socketPath))
        XCTAssertFalse(SecureFile.isOwnedSocket(atPath: regular))
        XCTAssertFalse(SecureFile.isOwnedSocket(atPath: regular + ".missing"))
    }

    // MARK: - Pidfile

    /// A daemon removing a pidfile on the way out must not remove the one its successor wrote.
    func testAPidfileIsOnlyRemovedByTheProcessItNames() throws {
        let directory = try makeDirectory(mode: 0o700)
        let path = directory.appendingPathComponent("UDID.pid").path
        let successor = DaemonRecord(pid: 4_242, udid: "UDID", executable: "/x/simprobe-daemon")
        try successor.write(to: path)

        XCTAssertFalse(DaemonRecord.removeIfOwned(path: path, pid: 999))
        XCTAssertEqual(DaemonRecord.read(from: path), successor)
        XCTAssertTrue(DaemonRecord.removeIfOwned(path: path, pid: 4_242))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(DaemonRecord.removeIfOwned(path: path, pid: 4_242))
    }

    /// Everything the daemon owns is 0600, the pidfile included, and none of it is written
    /// through a symlink somebody else planted.
    func testThePidfileIsWrittenPrivatelyAndReplacedInPlace() throws {
        let directory = try makeDirectory(mode: 0o700)
        let path = directory.appendingPathComponent("UDID.pid").path
        let first = DaemonRecord(pid: 1, udid: "UDID", executable: "/x/simprobe-daemon")
        let second = DaemonRecord(pid: 4_242, udid: "UDID", executable: "/x/simprobe-daemon")

        try first.write(to: path)
        try second.write(to: path)

        XCTAssertEqual(DaemonRecord.read(from: path), second)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)

        let link = directory.appendingPathComponent("linked.pid")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: directory.appendingPathComponent("victim"))
        XCTAssertThrowsError(try second.write(to: link.path)) { error in
            XCTAssertEqual((error as? ProbeError)?.exitCode, 5)
        }
    }

    /// A pid is only signalled when the path it was recorded with is a daemon's.
    func testNothingButADaemonBinaryIsEverSignalled() throws {
        let own = ProcessInfo.processInfo.processIdentifier
        let path = try XCTUnwrap(ProcessIdentity.executablePath(of: own))

        XCTAssertFalse(
            ProcessIdentity.isRunning(pid: own, executable: path),
            "the test runner is not a simprobe-daemon and must not be signallable"
        )
        // The suffix is a parameter so the identity check itself can still be proved against a
        // process that exists.
        XCTAssertTrue(ProcessIdentity.isRunning(pid: own, executable: path, mustEndWith: "xctest"))
        XCTAssertFalse(
            ProcessIdentity.isRunning(
                pid: own, executable: "/opt/simprobe-daemon", mustEndWith: "simprobe-daemon"))
        XCTAssertEqual(ProcessIdentity.daemonSuffix, "/simprobe-daemon")
        XCTAssertNil(ProcessIdentity.executablePath(of: 0))
    }

    // MARK: - Logging

    func testTheLogCreatesItsFileAndWritesOneJSONObjectPerEvent() throws {
        let directory = try makeDirectory(mode: 0o700)
        let path = directory.appendingPathComponent("UDID.log").path

        DaemonLog(path: path).write("starting", ["udid": "UDID"])
        DaemonLog(path: path).write("ready")

        let lines = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], "\(line)")
            XCTAssertNotNil(object["t"])
            XCTAssertNotNil(object["event"])
        }
    }

    /// A companion error routinely carries a tab or an escape sequence, and a raw control byte
    /// inside a quoted string is not JSON: the line would be unreadable by anything but eyes.
    func testControlCharactersAreEscapedRatherThanEmittedRaw() throws {
        let directory = try makeDirectory(mode: 0o700)
        let path = directory.appendingPathComponent("UDID.log").path
        let nasty = "a\u{01}b\tc\"d\\e\nf\u{1B}[0m"

        DaemonLog(path: path).write("failed", ["detail": nasty])

        let line = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(line.split(separator: "\n").count, 1, line)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], line)
        XCTAssertEqual(object["detail"] as? String, nasty)
        XCTAssertEqual(DaemonLog.escape("\u{01}"), "\\u0001")
        XCTAssertEqual(DaemonLog.escape("\u{1F}"), "\\u001f")
    }

    /// A log path that is a symlink is refused, and a daemon that cannot log still runs.
    func testAnUnwritableLogIsNotAnError() throws {
        let directory = try makeDirectory(mode: 0o700)
        let victim = directory.appendingPathComponent("victim")
        let link = directory.appendingPathComponent("UDID.log")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)

        DaemonLog(path: link.path).write("starting")

        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path))
    }

    // MARK: - Arguments

    func testTheDaemonCommandLineRoundTripsThroughTheLauncherAndTheParser() throws {
        let paths = DaemonPaths(base: URL(fileURLWithPath: "/var/tmp", isDirectory: true))
        let arguments =
            ["simprobe-daemon"]
            + [
                "--udid", "UDID",
                "--socket", paths.socket(udid: "UDID"),
                "--pid-file", paths.pidFile(udid: "UDID"),
                "--log", paths.log(udid: "UDID"),
                "--idle-timeout-ms", "600000",
            ]

        let parsed = try XCTUnwrap(DaemonArguments.parse(arguments))

        XCTAssertEqual(parsed.udid, "UDID")
        XCTAssertEqual(parsed.socketPath, "/var/tmp/simprobe/UDID.sock")
        XCTAssertEqual(parsed.pidFilePath, "/var/tmp/simprobe/UDID.pid")
        XCTAssertEqual(parsed.logPath, "/var/tmp/simprobe/UDID.log")
        XCTAssertEqual(parsed.idleTimeoutMs, 600_000)
    }

    func testAnIncompleteDaemonCommandLineIsRefusedRatherThanDefaulted() {
        let complete = [
            "simprobe-daemon", "--udid", "U", "--socket", "/s", "--pid-file", "/p", "--log", "/l",
        ]
        for arguments in [
            ["simprobe-daemon"],
            ["simprobe-daemon", "--udid"],
            ["simprobe-daemon", "--udid", ""],
            complete,
            complete + ["--idle-timeout-ms", "0"],
            complete + ["--idle-timeout-ms", "soon"],
        ] {
            XCTAssertNil(DaemonArguments.parse(arguments), "\(arguments)")
        }
        XCTAssertNotNil(DaemonArguments.parse(complete + ["--idle-timeout-ms", "1"]))
        XCTAssertTrue(DaemonArguments.usage.contains("--idle-timeout-ms"))
    }

    // MARK: - Harness

    private func makeDirectory(mode: Int) throws -> URL {
        let directory = URL(
            fileURLWithPath: "/var/tmp/sp-h-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: mode]
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func bindSocket(at path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, size)
            }
        }
        guard bound == 0 else {
            close(descriptor)
            throw ProbeError.captureFailed("could not bind \(path)")
        }
        return descriptor
    }
}
