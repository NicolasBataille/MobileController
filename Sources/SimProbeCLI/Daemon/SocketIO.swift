import Darwin
import Foundation

/// What one `read` or `write` on a socket actually meant.
///
/// Both sides of the daemon socket set `SO_RCVTIMEO`/`SO_SNDTIMEO`, and a timed-out syscall on a
/// blocking descriptor is indistinguishable from a peer hanging up unless `errno` is read: both
/// return a non-positive count. Telling them apart is the difference between "the daemon is
/// wedged, here is how long we waited" and "the daemon closed without answering" — two different
/// bugs with two different fixes, and the reason this is a type rather than a comparison.
public enum SocketOutcome: Equatable, Sendable {

    /// Bytes were transferred.
    case bytes(Int)

    /// A signal arrived mid-syscall. Not an error: the call is retried.
    case interrupted

    /// `SO_RCVTIMEO`/`SO_SNDTIMEO` expired with nothing transferred.
    case timedOut

    /// The peer closed the connection cleanly.
    case closed

    /// Anything else, carrying `errno`.
    case failed(Int32)
}

/// Reading and writing whole lines on a blocking socket with timeouts set.
public enum SocketIO {

    /// The most a single request line may carry, after which the peer is a fire hose rather than
    /// a client. 64 KB is far above the largest request this protocol defines (a `tap` is under
    /// forty bytes) and far below anything that could exhaust the daemon's memory.
    ///
    /// Responses are *not* capped this way: an accessibility tree is routinely 200 KB, and the
    /// side that receives those is the client, which asked for them.
    public static let maxRequestBytes = 64 * 1_024

    /// How long an accepted connection may stall before it is dropped, in milliseconds.
    ///
    /// Comfortably below the client's own 30 s budget: a client that has stopped talking has
    /// usually been killed, and the daemon must not keep a half-open connection ahead of the
    /// next caller in the accept queue.
    public static let connectionTimeoutMs = 10_000

    /// - Returns: what the syscall's return value and `errno` together mean.
    public static func classify(count: Int, errno code: Int32) -> SocketOutcome {
        if count > 0 { return .bytes(count) }
        if count == 0 { return .closed }
        switch code {
        case EINTR: return .interrupted
        case EAGAIN, EWOULDBLOCK: return .timedOut
        default: return .failed(code)
        }
    }

    /// Bounds both halves of an exchange on `descriptor`.
    ///
    /// - Returns: whether both options were accepted.
    @discardableResult
    public static func setTimeouts(on descriptor: Int32, ms: Int) -> Bool {
        var timeout = timeval(tv_sec: ms / 1_000, tv_usec: Int32((ms % 1_000) * 1_000))
        let size = socklen_t(MemoryLayout<timeval>.size)
        return [SO_RCVTIMEO, SO_SNDTIMEO].allSatisfy {
            setsockopt(descriptor, SOL_SOCKET, $0, &timeout, size) == 0
        }
    }
}

/// Accumulates bytes until a newline, refusing to grow past a cap.
///
/// A separate type because it is the only part of the socket loop that can be wrong in a way a
/// live test would not notice: a frame that arrives in three reads, and a peer that never sends
/// a terminator at all, both look like a working daemon right up until they do not.
public struct LineAccumulator: Equatable, Sendable {

    /// What the bytes so far amount to.
    public enum Step: Equatable, Sendable {

        /// A terminated line, with the terminator removed.
        case complete(String)

        /// No terminator yet, and room for more.
        case needsMore

        /// The cap was reached without a terminator.
        case overflow
    }

    private var accumulated = Data()
    private let limit: Int

    public init(limit: Int = SocketIO.maxRequestBytes) {
        self.limit = limit
    }

    /// Whether anything has arrived at all, which is how a clean hang-up is told from a
    /// truncated frame.
    public var isEmpty: Bool { accumulated.isEmpty }

    /// Everything received so far, terminator included.
    public var text: String { String(decoding: accumulated, as: UTF8.self) }

    public mutating func append(_ bytes: some Sequence<UInt8>) -> Step {
        accumulated.append(contentsOf: bytes)
        if let index = accumulated.firstIndex(of: DaemonProtocol.terminator) {
            return .complete(String(decoding: accumulated[..<index], as: UTF8.self))
        }
        return accumulated.count >= limit ? .overflow : .needsMore
    }
}
