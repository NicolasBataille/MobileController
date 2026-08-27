import Foundation

/// Talking to a warm daemon, behind a protocol so every verb above it is testable without one.
public protocol DaemonClient: Sendable {

    /// - Throws: `ProbeError.daemonUnavailable` (exit 2) when no daemon is listening,
    ///   `ProbeError.idbFailed` (exit 2) when one is but the exchange failed.
    func send(_ request: DaemonRequest) throws -> DaemonResponse
}

extension DaemonClient {

    /// Sends, and turns an in-band failure back into a `throw`.
    @discardableResult
    public func call(_ request: DaemonRequest) throws -> DaemonResponse {
        try DaemonProtocol.unwrap(try send(request), op: request.op)
    }

    /// Whether a daemon answered a `ping`.
    public var isRunning: Bool {
        ((try? send(.ping))?.ok) == true
    }

    /// Whether a daemon answered a `ping` *and* has finished reaching the companion.
    ///
    /// The distinction is the whole of the start sequence: the daemon binds its socket first so
    /// that `start` can never orphan a process it cannot find, which means "answering" arrives
    /// seconds before "usable".
    public var isReady: Bool {
        guard let response = try? send(.ping) else { return false }
        return response.ok && response.connecting != true
    }
}

/// The real one: one `AF_UNIX` connection per request.
///
/// A connection per request rather than a kept-open one because the connect costs tens of
/// microseconds on a local socket — nothing next to the 1.1 ms tap it carries — and it removes
/// every reconnect-after-idle question from the client side. What is expensive is the *gRPC*
/// connection to the companion, and that one is held for the daemon's whole life.
public struct UnixSocketDaemonClient: DaemonClient {

    /// How long a request may take end to end. Generous next to a 70 ms tree because the first
    /// call after a boot goes through the companion's own connect.
    public static let defaultTimeoutMs = 30_000

    private let path: String
    private let udid: String
    private let timeoutMs: Int

    public init(path: String, udid: String, timeoutMs: Int = defaultTimeoutMs) {
        self.path = path
        self.udid = udid
        self.timeoutMs = timeoutMs
    }

    public func send(_ request: DaemonRequest) throws -> DaemonResponse {
        let descriptor = try connect()
        defer { close(descriptor) }
        try write(try DaemonProtocol.encode(request) + "\n", to: descriptor)
        return try DaemonProtocol.decodeResponse(try readLine(from: descriptor))
    }

    // MARK: Socket

    private func connect() throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count <= DaemonPaths.socketPathLimit else {
            throw ProbeError.captureFailed("socket path is \(bytes.count) bytes: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ProbeError.daemonUnavailable(udid: udid)
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, size)
            }
        }
        guard connected == 0 else {
            close(descriptor)
            throw ProbeError.daemonUnavailable(udid: udid)
        }
        try setTimeouts(on: descriptor)
        return descriptor
    }

    /// Bounds both halves of the exchange, so a wedged daemon fails instead of pinning the CLI.
    private func setTimeouts(on descriptor: Int32) throws {
        guard SocketIO.setTimeouts(on: descriptor, ms: timeoutMs) else {
            throw ProbeError.idbFailed(command: "daemon", detail: "could not set a timeout")
        }
    }

    private func write(_ text: String, to descriptor: Int32) throws {
        var remaining = Array(text.utf8)[...]
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress, buffer.count)
            }
            switch SocketIO.classify(count: written, errno: errno) {
            case .bytes(let count):
                remaining = remaining.dropFirst(count)
            case .interrupted:
                continue
            case .timedOut:
                throw Self.timedOut(timeoutMs, half: "send")
            case .closed, .failed:
                throw ProbeError.idbFailed(command: "daemon", detail: "the socket closed on write")
            }
        }
    }

    /// Reads until the first newline. The response is one line by construction.
    ///
    /// The three ways this can end are three different diagnoses: a frame, a daemon that hung up
    /// without answering, and a daemon that is still holding the connection open with nothing to
    /// say. Reporting the last two the same way — which is what a bare `count > 0` check does —
    /// sends whoever reads the message looking for the wrong bug.
    private func readLine(from descriptor: Int32) throws -> String {
        var accumulator = LineAccumulator(limit: Int.max)
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            switch SocketIO.classify(count: count, errno: errno) {
            case .bytes(let read):
                if case .complete(let line) = accumulator.append(buffer[0..<read]) { return line }
            case .interrupted:
                continue
            case .timedOut:
                throw Self.timedOut(timeoutMs, half: "answer")
            case .closed, .failed:
                guard !accumulator.isEmpty else {
                    throw ProbeError.idbFailed(
                        command: "daemon",
                        detail: "the daemon closed the connection without answering"
                    )
                }
                return accumulator.text
            }
        }
    }

    /// The message a wedged daemon produces, which has to name the wait: "no answer" and "no
    /// answer *after thirty seconds*" send a reader to different places.
    static func timedOut(_ ms: Int, half: String) -> ProbeError {
        .idbFailed(command: "daemon", detail: "the daemon timed out after \(ms) ms on \(half)")
    }
}
