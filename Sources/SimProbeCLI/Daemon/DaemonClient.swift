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
        var timeout = timeval(
            tv_sec: timeoutMs / 1_000,
            tv_usec: Int32((timeoutMs % 1_000) * 1_000)
        )
        let size = socklen_t(MemoryLayout<timeval>.size)
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
            guard setsockopt(descriptor, SOL_SOCKET, option, &timeout, size) == 0 else {
                throw ProbeError.idbFailed(command: "daemon", detail: "could not set a timeout")
            }
        }
    }

    private func write(_ text: String, to descriptor: Int32) throws {
        var remaining = Array(text.utf8)[...]
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress, buffer.count)
            }
            guard written > 0 else {
                throw ProbeError.idbFailed(command: "daemon", detail: "the socket closed on write")
            }
            remaining = remaining.dropFirst(written)
        }
    }

    /// Reads until the first newline. The response is one line by construction.
    private func readLine(from descriptor: Int32) throws -> String {
        var accumulated = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count > 0 else {
                guard !accumulated.isEmpty else {
                    throw ProbeError.idbFailed(
                        command: "daemon",
                        detail: "the daemon closed the connection without answering"
                    )
                }
                break
            }
            accumulated.append(contentsOf: buffer[0..<count])
            if accumulated.last == DaemonProtocol.terminator { break }
        }
        return String(decoding: accumulated, as: UTF8.self)
    }
}
