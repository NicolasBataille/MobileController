import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import SimProbeCLI

/// The gRPC half of the daemon: the only file in this repository that talks to `idb_companion`.
///
/// An `actor` because the warm channel's health is mutable state read and written by every call,
/// and the whole design rests on there being exactly one channel.
@available(macOS 15, *)
actor IdbCompanionActor: IdbActing {

    typealias CompanionClient = Idb_CompanionService.Client<HTTP2ClientTransport.Posix>

    /// Where `idb_companion` listens for a given simulator. Not configurable: this path is idb's
    /// own convention and a daemon pointed anywhere else would simply find nothing.
    static func companionSocket(udid: String) -> String { "/tmp/idb/\(udid)_companion.sock" }

    private let warm: CompanionClient
    private let udid: String
    private let log: DaemonLog

    /// Whether the long-lived channel is still worth trying first.
    ///
    /// Once a call has failed on it, every later call goes straight to a fresh channel: retrying
    /// a dead channel first would charge each call the failure *and* the reconnect.
    private var warmIsHealthy = true

    init(warm: CompanionClient, udid: String, log: DaemonLog) {
        self.warm = warm
        self.udid = udid
        self.log = log
    }

    func tap(x: Double, y: Double) async throws {
        try await run("hid") { client in
            _ = try await client.hid(
                request: StreamingClientRequest(of: Idb_HIDEvent.self) { writer in
                    for event in Self.tapEvents(x: x, y: y) { try await writer.write(event) }
                }
            ) { try $0.message }
        }
    }

    func treeJSON() async throws -> String {
        try await run("accessibility_info") { client in
            var request = Idb_AccessibilityInfoRequest()
            // `.legacy` is what `idb ui describe-all --json` asks for, and the flat array this
            // repository's parser already reads. The newer formats are not understood by every
            // released companion.
            request.format = .legacy
            return try await client.accessibility_info(request: ClientRequest(message: request)) {
                try $0.message.json
            }
        }
    }

    /// Runs one call, reconnecting **once** on failure.
    ///
    /// The first call after a simulator boots reliably fails with "No translation object
    /// returned": the companion is up, its bridge to the simulator is not, and an explicit `idb
    /// connect` establishes it. That is the same retry `IdbElementDescriber` does for the CLI
    /// path, for the same reason. A second failure is reported to the client and the daemon
    /// keeps serving — a companion that died mid-loop must not take the warm process with it.
    private func run<R: Sendable>(
        _ label: String,
        _ body: @Sendable (CompanionClient) async throws -> R
    ) async throws -> R {
        if warmIsHealthy {
            do {
                return try await body(warm)
            } catch {
                warmIsHealthy = false
                log.write("warm-channel-lost", ["call": label, "detail": "\(error)"])
            }
        }
        do {
            return try await withFreshChannel(body)
        } catch {
            reconnectCompanion()
            do {
                return try await withFreshChannel(body)
            } catch {
                throw ProbeError.idbFailed(command: label, detail: "\(error)")
            }
        }
    }

    private func withFreshChannel<R: Sendable>(
        _ body: @Sendable (CompanionClient) async throws -> R
    ) async throws -> R {
        try await withGRPCClient(
            transport: .http2NIOPosix(
                target: .unixDomainSocket(path: Self.companionSocket(udid: udid)),
                transportSecurity: .plaintext
            )
        ) { grpc in
            try await body(CompanionClient(wrapping: grpc))
        }
    }

    /// `idb connect <udid>`, whose only job is to re-establish the companion's bridge.
    ///
    /// A failure is deliberately not reported: what the caller needs to hear about is the retry
    /// that follows, whose error is the one that actually stopped the call.
    private func reconnectCompanion() {
        guard let idb = try? Idb.locate() else { return }
        log.write("idb-connect", ["udid": udid])
        _ = try? SystemProcessRunner().run(
            idb, ["connect", udid], deadlineMs: Idb.describeDeadlineMs)
    }

    /// A press and a release at the same point, which is what a tap is on the HID stream.
    private static func tapEvents(x: Double, y: Double) -> [Idb_HIDEvent] {
        var point = Idb_Point()
        point.x = x
        point.y = y
        var touch = Idb_HIDEvent.HIDTouch()
        touch.point = point
        var action = Idb_HIDEvent.HIDPressAction()
        action.touch = touch
        return [Idb_HIDEvent.HIDDirection.down, .up].map { direction in
            var press = Idb_HIDEvent.HIDPress()
            press.action = action
            press.direction = direction
            var event = Idb_HIDEvent()
            event.press = press
            return event
        }
    }
}
