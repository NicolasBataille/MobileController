import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import SimProbeCLI

/// The gRPC half of the daemon: the only file in this repository that talks to `idb_companion`.
///
/// An `actor` because the live channel and its health are mutable state read and written by
/// every call, and the whole design rests on there being exactly one channel at a time.
@available(macOS 15, *)
actor IdbCompanionActor: IdbActing {

    typealias CompanionClient = Idb_CompanionService.Client<HTTP2ClientTransport.Posix>
    typealias Channel = GRPCClient<HTTP2ClientTransport.Posix>

    /// Where `idb_companion` listens for a given simulator. Not configurable: this path is idb's
    /// own convention and a daemon pointed anywhere else would simply find nothing.
    static func companionSocket(udid: String) -> String { "/tmp/idb/\(udid)_companion.sock" }

    /// How long any one RPC may take.
    ///
    /// Below the client's 30 s `SO_RCVTIMEO`, and by enough to matter: a call that expires here
    /// answers the socket in band with a message naming the timeout, whereas a call that outlives
    /// the client's own budget reaches it as "the daemon closed the connection" — a wrong
    /// diagnosis of a daemon that is alive and still working. 20 s is generous next to a 70 ms
    /// tree and a 1.1 ms tap; nothing legitimate is anywhere near it.
    static let callTimeoutMs = 20_000

    private let warm: CompanionClient
    private let udid: String
    private let log: DaemonLog

    /// A channel opened after the warm one failed and kept because it worked.
    ///
    /// Without this every later call pays a fresh connect. With it, a companion that dies and
    /// comes back costs one slow call rather than all of them.
    private var adopted: AdoptedChannel?

    /// Whether the channel in use is still worth trying first.
    ///
    /// Once a call has failed on it, the next one goes straight to a fresh channel: retrying a
    /// dead channel first would charge each call the failure *and* the reconnect. It goes back
    /// to `true` when a fresh channel is adopted, which is what stops a single hiccup from
    /// condemning the daemon to reconnect on every call for the rest of its life.
    private var channelIsHealthy = true

    init(warm: CompanionClient, udid: String, log: DaemonLog) {
        self.warm = warm
        self.udid = udid
        self.log = log
    }

    deinit {
        adopted?.close()
    }

    func tap(x: Double, y: Double) async throws {
        try await run("hid") { client in
            _ = try await client.hid(
                request: StreamingClientRequest(of: Idb_HIDEvent.self) { writer in
                    for event in Self.tapEvents(x: x, y: y) { try await writer.write(event) }
                },
                options: Self.callOptions
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
            return try await client.accessibility_info(
                request: ClientRequest(message: request),
                options: Self.callOptions
            ) { try $0.message.json }
        }
    }

    /// Every call carries a deadline. Without one, a companion that accepts a connection and
    /// then says nothing pins the daemon's one serving thread until the client gives up.
    private static var callOptions: CallOptions {
        var options = CallOptions.defaults
        options.timeout = .milliseconds(callTimeoutMs)
        return options
    }

    /// Runs one call, reconnecting **once** on failure.
    ///
    /// The first call after a simulator boots reliably fails with "No translation object
    /// returned": the companion is up, its bridge to the simulator is not, and an explicit `idb
    /// connect` establishes it. That is the same retry `IdbElementDescriber` does for the CLI
    /// path, for the same reason. A second failure is reported to the client and the daemon
    /// keeps serving — a companion that died mid-loop must not take the warm process with it.
    ///
    /// A **deadline** is the one failure that does not enter that ladder. Retrying it would
    /// spend another twenty seconds, and the sum is past the client's own budget: the caller
    /// would be told the daemon had closed the connection while it was still working.
    private func run<R: Sendable>(
        _ label: String,
        _ body: @Sendable (CompanionClient) async throws -> R
    ) async throws -> R {
        if channelIsHealthy {
            do {
                return try await body(current)
            } catch let error as RPCError where error.code == .deadlineExceeded {
                throw timedOut(label)
            } catch {
                channelIsHealthy = false
                log.write("warm-channel-lost", ["call": label, "detail": "\(error)"])
            }
        }
        do {
            return try await withFreshChannel(body)
        } catch let error as RPCError where error.code == .deadlineExceeded {
            throw timedOut(label)
        } catch {
            reconnectCompanion()
            do {
                return try await withFreshChannel(body)
            } catch let error as RPCError where error.code == .deadlineExceeded {
                throw timedOut(label)
            } catch {
                throw ProbeError.idbFailed(command: label, detail: "\(error)")
            }
        }
    }

    /// The channel calls go to: the one adopted after a reconnect, or the one opened at startup.
    private var current: CompanionClient { adopted?.client ?? warm }

    /// Marks the channel unusable and words the failure the way the client needs to read it.
    private func timedOut(_ label: String) -> ProbeError {
        channelIsHealthy = false
        log.write("call-timeout", ["call": label, "ms": "\(Self.callTimeoutMs)"])
        return .idbFailed(
            command: label,
            detail: "the companion did not answer within \(Self.callTimeoutMs) ms"
        )
    }

    /// Opens a channel, and keeps it if the call on it worked.
    ///
    /// The channel is run by a task of its own rather than by `withGRPCClient`, whose scope ends
    /// with the call: keeping it is the whole point, because the connect is the expensive part.
    private func withFreshChannel<R: Sendable>(
        _ body: @Sendable (CompanionClient) async throws -> R
    ) async throws -> R {
        let transport = try HTTP2ClientTransport.Posix(
            target: .unixDomainSocket(path: Self.companionSocket(udid: udid)),
            transportSecurity: .plaintext
        )
        let channel = Channel(transport: transport)
        let connections = Task { _ = try? await channel.runConnections() }
        let fresh = AdoptedChannel(channel: channel, connections: connections)
        do {
            let result = try await body(CompanionClient(wrapping: channel))
            // Replaced only on success, and the one being replaced is shut down: a daemon that
            // reconnects a dozen times over an afternoon must not be holding a dozen channels.
            adopted?.close()
            adopted = fresh
            channelIsHealthy = true
            log.write("channel-adopted")
            return result
        } catch {
            fresh.close()
            throw error
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

    /// A kept channel and the task running its connections, which have to end together.
    private struct AdoptedChannel: Sendable {

        let channel: Channel
        let connections: Task<Void, Never>

        var client: CompanionClient { CompanionClient(wrapping: channel) }

        func close() {
            channel.beginGracefulShutdown()
            connections.cancel()
        }
    }
}
