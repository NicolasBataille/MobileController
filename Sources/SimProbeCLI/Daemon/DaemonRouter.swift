import Foundation

/// The two things the daemon can do to a simulator, behind a protocol.
///
/// This is the whole gRPC surface, stated in nine lines with no gRPC in sight — which is what
/// lets the routing above it be tested in the same bundle as everything else while grpc-swift
/// stays out of the test binary entirely.
public protocol IdbActing: Sendable {

    /// One HID press-and-release at a point in logical points.
    func tap(x: Double, y: Double) async throws

    /// idb's accessibility JSON for what is on screen, verbatim.
    func treeJSON() async throws -> String
}

/// A monotonic microsecond counter.
///
/// Microseconds and not `ProbeClock`'s milliseconds because the number this measures is a **1.1
/// ms** tap: rounded to whole milliseconds it would read as 1 or 2, and the whole point of the
/// daemon is that this figure is small enough to be awkward to measure.
public protocol MonotonicTicker: Sendable {
    var nowMicroseconds: Int { get }
}

public struct SystemTicker: MonotonicTicker {

    public init() {}

    public var nowMicroseconds: Int { Int(DispatchTime.now().uptimeNanoseconds / 1_000) }
}

/// What the router decided: the line to write back, and whether to keep serving.
public struct DaemonReply: Equatable, Sendable {

    public let response: DaemonResponse
    public let shouldStop: Bool

    public init(response: DaemonResponse, shouldStop: Bool = false) {
        self.response = response
        self.shouldStop = shouldStop
    }
}

/// Turns one request into one reply.
///
/// Pure dispatch with no I/O of its own: the socket is above it, the gRPC is below it, and what
/// is between — which operation calls what, how long it took, how a failure is worded — is the
/// part worth having tests for.
public struct DaemonRouter: Sendable {

    private let actor: any IdbActing
    private let udid: String
    private let pid: Int32
    private let ticker: any MonotonicTicker
    private let startedAtMicroseconds: Int

    public init(
        actor: any IdbActing,
        udid: String,
        pid: Int32,
        ticker: any MonotonicTicker = SystemTicker(),
        startedAtMicroseconds: Int
    ) {
        self.actor = actor
        self.udid = udid
        self.pid = pid
        self.ticker = ticker
        self.startedAtMicroseconds = startedAtMicroseconds
    }

    public func reply(to request: DaemonRequest) async -> DaemonReply {
        switch request.op {
        case .ping:
            return DaemonReply(
                response: DaemonResponse(
                    ok: true,
                    pid: pid,
                    udid: udid,
                    uptimeMs: (ticker.nowMicroseconds - startedAtMicroseconds) / 1_000
                )
            )
        case .stop:
            return DaemonReply(response: DaemonResponse(ok: true), shouldStop: true)
        case .tree:
            return await measured { try await $0.treeJSON() }
        case .tap:
            guard let x = request.x, let y = request.y else {
                return DaemonReply(response: .failure(.invalidArgument("tap needs both x and y")))
            }
            return await measured {
                try await $0.tap(x: x, y: y)
                return nil
            }
        }
    }

    /// Runs `body`, times it, and turns anything it throws into an in-band failure.
    ///
    /// A failing call must not take the daemon down: the companion dying mid-loop is exactly the
    /// case this design has to survive, and a client that gets `ok: false` can retry against a
    /// process that is still warm.
    private func measured(_ body: (any IdbActing) async throws -> String?) async -> DaemonReply {
        let started = ticker.nowMicroseconds
        do {
            let tree = try await body(actor)
            return DaemonReply(
                response: DaemonResponse(
                    ok: true,
                    ms: Self.milliseconds(since: started, now: ticker.nowMicroseconds),
                    treeJSON: tree
                )
            )
        } catch let error as ProbeError {
            return DaemonReply(response: .failure(error))
        } catch {
            return DaemonReply(
                response: .failure(.idbFailed(command: "daemon", detail: "\(error)")))
        }
    }

    /// Elapsed milliseconds to two decimals: enough to tell 0.5 ms from 1.1 ms, few enough that
    /// the response line stays short.
    static func milliseconds(since started: Int, now: Int) -> Double {
        (Double(max(now - started, 0)) / 10.0).rounded() / 100.0
    }
}
