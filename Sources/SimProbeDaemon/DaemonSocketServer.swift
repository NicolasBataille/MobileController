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
/// `@unchecked Sendable` because everything the compiler can see is immutable after `init` and
/// the one piece that is not — whether a stop has been asked for — is behind its own lock:
/// `serve` runs on the socket thread for the daemon's whole life, and `requestStop` is called
/// from the task that owns the gRPC channel when the companion turns out to be unreachable.
final class DaemonSocketServer: @unchecked Sendable {

    /// How many connections the kernel may queue while a request is in flight.
    private static let backlog: Int32 = 8

    private let descriptor: Int32
    private let path: String
    private let log: DaemonLog

    /// Which node `bind` created, taken the instant afterwards.
    ///
    /// The socket file is unlinked on the way out, and by then the path may name something
    /// else entirely — a socket a *successor* daemon bound after a slow shutdown, or whatever
    /// a local attacker put there. Unlinking by name would delete it; unlinking by identity
    /// does nothing, which is the correct amount of damage.
    private let identity: SecureFile.NodeIdentity?

    private let state = State()

    /// - Throws: `ProbeError.captureFailed` (exit 5) when the socket cannot be bound.
    init(path: String, log: DaemonLog) throws {
        self.path = path
        self.log = log
        guard path.utf8.count <= DaemonPaths.socketPathLimit else {
            throw ProbeError.captureFailed("socket path is \(path.utf8.count) bytes: \(path)")
        }
        // A socket file left by a crashed daemon is not a listener; unlinking it is the only way
        // to bind the same path again, and `daemon start` has already established that nothing
        // is answering on it. What is *not* established is that the thing at that path is one of
        // ours: a regular file, a directory or somebody else's socket is refused rather than
        // deleted, because a daemon that removes arbitrary files is a worse bug than one that
        // will not start.
        if SecureFile.identity(ofPath: path) != nil {
            guard SecureFile.isOwnedSocket(atPath: path) else {
                throw ProbeError.captureFailed(
                    "\(path) exists and is not a socket owned by this user; refusing to remove it")
            }
            unlink(path)
        }
        // A local rather than the property until `bind` is done: the closure below may not
        // touch `self` while a stored property is still uninitialised.
        let listening = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listening >= 0 else {
            throw ProbeError.captureFailed("could not create a socket: \(errno)")
        }
        descriptor = listening
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        // The socket is an unauthenticated command channel onto a simulator, and `bind` applies
        // the umask: created 0600 rather than created 0777 and narrowed a moment later, which is
        // a window a local process can connect through.
        let previousMask = umask(0o077)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listening, $0, size) }
        }
        umask(previousMask)
        guard bound == 0, listen(listening, Self.backlog) == 0 else {
            close(listening)
            throw ProbeError.captureFailed("could not bind \(path): \(errno)")
        }
        // Belt and braces: a `umask` an ancestor process set to something exotic is honoured by
        // `bind`, and this is the mode that matters.
        chmod(path, SecureFile.fileMode)
        identity = SecureFile.identity(ofPath: path)
    }

    deinit {
        closeListening()
        SecureFile.unlink(path: path, matching: identity)
    }

    /// Serves until a `stop` request arrives, the idle timeout expires, or `requestStop` is
    /// called.
    ///
    /// - Parameter handle: answers one request. Synchronous on purpose — the caller bridges to
    ///   the async gRPC world, and keeping the bridge in one place keeps this loop readable.
    func serve(idleTimeoutMs: Int, handle: (DaemonRequest) -> DaemonReply) {
        while !state.isStopping {
            guard waitForConnection(idleTimeoutMs: idleTimeoutMs) else {
                if !state.isStopping { log.write("idle-timeout", ["ms": "\(idleTimeoutMs)"]) }
                return
            }
            let connection = accept(descriptor, nil, nil)
            guard connection >= 0 else {
                if errno == EINTR { continue }
                return
            }
            defer { close(connection) }
            // A client that connects and then stops talking must not hold the next caller behind
            // it: this is the only place in the daemon where an unknown peer sets the pace.
            SocketIO.setTimeouts(on: connection, ms: SocketIO.connectionTimeoutMs)
            guard answer(on: connection, handle: handle) else { return }
        }
    }

    /// Ends the accept loop from another thread, for a daemon that has decided to give up.
    ///
    /// Closing the listening descriptor is what wakes a `poll` that would otherwise sit there
    /// for the whole idle timeout.
    func requestStop() {
        state.setStopping()
        closeListening()
    }

    /// - Returns: whether to keep serving.
    private func answer(on connection: Int32, handle: (DaemonRequest) -> DaemonReply) -> Bool {
        let reply: DaemonReply
        switch readRequest(from: connection) {
        case .line(let line):
            reply = decoded(line, handle: handle)
        case .none:
            return true
        case .timedOut:
            log.write("client-timeout", ["ms": "\(SocketIO.connectionTimeoutMs)"])
            return true
        case .tooLarge:
            log.write("request-too-large", ["limit": "\(SocketIO.maxRequestBytes)"])
            reply = DaemonReply(
                response: .failure(
                    .invalidArgument(
                        "a request may not exceed \(SocketIO.maxRequestBytes) bytes")))
        }
        if let encoded = try? DaemonProtocol.encode(reply.response) {
            write(encoded + "\n", to: connection)
        }
        if reply.shouldStop { log.write("stop-requested") }
        return !reply.shouldStop
    }

    private func decoded(_ line: String, handle: (DaemonRequest) -> DaemonReply) -> DaemonReply {
        do {
            return handle(try DaemonProtocol.decodeRequest(line))
        } catch let error as ProbeError {
            return DaemonReply(response: .failure(error))
        } catch {
            return DaemonReply(
                response: .failure(.idbFailed(command: "daemon", detail: "\(error)")))
        }
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

    /// What one connection had to say.
    private enum Request {
        case line(String)

        /// The peer hung up without sending a whole one.
        case none

        /// The peer stopped talking mid-frame.
        case timedOut

        /// The peer is a fire hose.
        case tooLarge
    }

    private func readRequest(from connection: Int32) -> Request {
        var accumulator = LineAccumulator()
        var buffer = [UInt8](repeating: 0, count: 8 * 1_024)
        while true {
            let count = read(connection, &buffer, buffer.count)
            switch SocketIO.classify(count: count, errno: errno) {
            case .bytes(let read):
                switch accumulator.append(buffer[0..<read]) {
                case .complete(let line): return .line(line)
                case .overflow: return .tooLarge
                case .needsMore: continue
                }
            case .interrupted:
                continue
            case .timedOut:
                return accumulator.isEmpty ? .none : .timedOut
            case .closed, .failed:
                return accumulator.isEmpty ? .none : .line(accumulator.text)
            }
        }
    }

    private func write(_ text: String, to connection: Int32) {
        var remaining = Array(text.utf8)[...]
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes {
                Darwin.write(connection, $0.baseAddress, $0.count)
            }
            switch SocketIO.classify(count: written, errno: errno) {
            case .bytes(let count):
                remaining = remaining.dropFirst(count)
            case .interrupted:
                continue
            case .timedOut:
                log.write("client-timeout", ["half": "write"])
                return
            case .closed, .failed:
                return
            }
        }
    }

    private func closeListening() {
        guard state.claimClose() else { return }
        close(descriptor)
    }

    /// The one piece of mutable state, shared between the socket thread and whoever gives up.
    private final class State: @unchecked Sendable {

        private let lock = NSLock()
        private var stopping = false
        private var closed = false

        var isStopping: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopping
        }

        func setStopping() {
            lock.lock()
            stopping = true
            lock.unlock()
        }

        /// - Returns: whether this caller is the one that has to close the descriptor.
        func claimClose() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !closed else { return false }
            closed = true
            return true
        }
    }
}
