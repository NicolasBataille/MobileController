import Darwin
import Foundation
import SimProbeCLI

/// The listening half of the daemon: one `AF_UNIX` socket, one client at a time.
///
/// Blocking syscalls on a thread of its own rather than non-blocking I/O in the cooperative
/// pool. A non-blocking accept loop would have to poll, and a poll interval long enough not to
/// spin is long enough to double the cost of a **1.1 ms** tap — which is the entire point of
/// this daemon. One dedicated thread, blocking, costs nothing and adds no latency.
///
/// Serial by construction: a simulator has one screen, and two taps racing on it are a bug.
///
/// `@unchecked Sendable` because it is handed to exactly one thread and touched by nothing else:
/// `serve` runs on the socket thread for the daemon's whole life, and the only other member the
/// compiler can see — the listening descriptor — is immutable.
final class DaemonSocketServer: @unchecked Sendable {

    /// How many connections the kernel may queue while a request is in flight.
    private static let backlog: Int32 = 8

    private let descriptor: Int32
    private let path: String
    private let log: DaemonLog

    /// - Throws: `ProbeError.captureFailed` (exit 5) when the socket cannot be bound.
    init(path: String, log: DaemonLog) throws {
        self.path = path
        self.log = log
        guard path.utf8.count <= DaemonPaths.socketPathLimit else {
            throw ProbeError.captureFailed("socket path is \(path.utf8.count) bytes: \(path)")
        }
        // A socket file left by a crashed daemon is not a listener; unlinking it is the only way
        // to bind the same path again. `daemon start` has already established that nothing is
        // answering on it.
        unlink(path)
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ProbeError.captureFailed("could not create a socket: \(errno)")
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, size) }
        }
        guard bound == 0, listen(descriptor, Self.backlog) == 0 else {
            close(descriptor)
            throw ProbeError.captureFailed("could not bind \(path): \(errno)")
        }
        // The socket is an unauthenticated command channel onto a simulator: owner only.
        chmod(path, 0o600)
    }

    deinit {
        close(descriptor)
        unlink(path)
    }

    /// Serves until a `stop` request arrives or the idle timeout expires.
    ///
    /// - Parameter handle: answers one request. Synchronous on purpose — the caller bridges to
    ///   the async gRPC world, and keeping the bridge in one place keeps this loop readable.
    func serve(idleTimeoutMs: Int, handle: (DaemonRequest) -> DaemonReply) {
        while true {
            guard waitForConnection(idleTimeoutMs: idleTimeoutMs) else {
                log.write("idle-timeout", ["ms": "\(idleTimeoutMs)"])
                return
            }
            let connection = accept(descriptor, nil, nil)
            guard connection >= 0 else { continue }
            defer { close(connection) }
            guard answer(on: connection, handle: handle) else { return }
        }
    }

    /// - Returns: whether to keep serving.
    private func answer(on connection: Int32, handle: (DaemonRequest) -> DaemonReply) -> Bool {
        guard let line = readLine(from: connection) else { return true }
        let reply: DaemonReply
        do {
            reply = handle(try DaemonProtocol.decodeRequest(line))
        } catch let error as ProbeError {
            reply = DaemonReply(response: .failure(error))
        } catch {
            reply = DaemonReply(
                response: .failure(.idbFailed(command: "daemon", detail: "\(error)")))
        }
        if let encoded = try? DaemonProtocol.encode(reply.response) {
            write(encoded + "\n", to: connection)
        }
        if reply.shouldStop { log.write("stop-requested") }
        return !reply.shouldStop
    }

    /// - Returns: false when the idle timeout expired with nothing connecting.
    private func waitForConnection(idleTimeoutMs: Int) -> Bool {
        var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        while true {
            let ready = poll(&poller, 1, Int32(idleTimeoutMs))
            if ready > 0 { return true }
            if ready == 0 { return false }
            // Interrupted by a signal rather than an error: resume waiting.
            if errno != EINTR { return false }
        }
    }

    private func readLine(from connection: Int32) -> String? {
        var accumulated = Data()
        var buffer = [UInt8](repeating: 0, count: 8 * 1_024)
        while true {
            let count = read(connection, &buffer, buffer.count)
            guard count > 0 else { return accumulated.isEmpty ? nil : decode(accumulated) }
            accumulated.append(contentsOf: buffer[0..<count])
            if accumulated.last == DaemonProtocol.terminator { return decode(accumulated) }
        }
    }

    private func decode(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    private func write(_ text: String, to connection: Int32) {
        var remaining = Array(text.utf8)[...]
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes {
                Darwin.write(connection, $0.baseAddress, $0.count)
            }
            guard written > 0 else { return }
            remaining = remaining.dropFirst(written)
        }
    }
}
