import Darwin
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import SimProbeCLI

/// The daemon's life: bind, answer, connect, serve until told to stop or until nobody has asked
/// in a while, then leave nothing behind.
///
/// The order matters. The socket is bound and answering `ping` **before** `idb connect` is
/// attempted, because `simprobe daemon start` gives up after thirty seconds and a daemon it can
/// no longer see is a daemon nobody will ever stop. While connecting, `ping` says so and the two
/// operations that need a companion refuse in band; `stop` works throughout.
@available(macOS 15, *)
enum DaemonEntry {

    /// How long to wait for `idb connect` to produce a companion socket, polled.
    ///
    /// Deliberately shorter than `DaemonLaunchOptions.defaultReadyTimeoutMs`: when the companion
    /// cannot be reached, the daemon must be the one that gives up first, so that `start` fails
    /// against a process that has already gone rather than against one it has to hunt for.
    private static let companionWaitMs = 25_000
    private static let companionPollMs = 100

    static func run(_ arguments: DaemonArguments) async -> Int32 {
        let log = DaemonLog(path: arguments.logPath)
        log.write("starting", ["udid": arguments.udid, "socket": arguments.socketPath])
        let pid = ProcessInfo.processInfo.processIdentifier
        do {
            let server = try DaemonSocketServer(path: arguments.socketPath, log: log)
            try DaemonRecord(pid: pid, udid: arguments.udid, executable: executablePath())
                .write(to: arguments.pidFilePath)
            // Only ever our own: between here and the exit, a second daemon may have started and
            // written its pidfile, and removing that one would leave it unstoppable.
            defer { DaemonRecord.removeIfOwned(path: arguments.pidFilePath, pid: pid) }
            let ticker = SystemTicker()
            let routing = Routing(
                DaemonRouter(
                    actor: nil,
                    udid: arguments.udid,
                    pid: pid,
                    ticker: ticker,
                    startedAtMicroseconds: ticker.nowMicroseconds
                )
            )
            let serving = Task {
                await serve(
                    server: server, idleTimeoutMs: arguments.idleTimeoutMs, routing: routing)
            }
            do {
                try await waitForCompanion(udid: arguments.udid, log: log)
            } catch {
                // The daemon puts itself down rather than sitting on a bound socket it can do
                // nothing with. The log line is the one `start` points at.
                log.write("companion-unreachable", ["udid": arguments.udid, "detail": "\(error)"])
                server.requestStop()
                await serving.value
                throw error
            }
            try await withGRPCClient(
                transport: .http2NIOPosix(
                    target: .unixDomainSocket(
                        path: IdbCompanionActor.companionSocket(udid: arguments.udid)),
                    transportSecurity: .plaintext
                )
            ) { grpc in
                routing.adopt(
                    DaemonRouter(
                        actor: IdbCompanionActor(
                            warm: IdbCompanionActor.CompanionClient(wrapping: grpc),
                            udid: arguments.udid,
                            log: log
                        ),
                        udid: arguments.udid,
                        pid: pid,
                        ticker: ticker,
                        startedAtMicroseconds: ticker.nowMicroseconds
                    )
                )
                log.write("ready")
                // Returns immediately when a `stop` arrived while we were connecting, which is
                // the price of not being able to cancel a blocking `idb connect`.
                await serving.value
            }
            log.write("stopped")
            return 0
        } catch let error as ProbeError {
            log.write("failed", ["detail": error.description])
            FileHandle.standardError.write(Data("simprobe-daemon: \(error)\n".utf8))
            return error.exitCode
        } catch {
            log.write("failed", ["detail": "\(error)"])
            return 2
        }
    }

    /// Runs the accept loop on a thread of its own and waits for it to finish.
    ///
    /// The socket loop is synchronous and runs on a thread of its own; the bridge back into the
    /// async world is one semaphore per request. A blocking wait is safe there precisely because
    /// that thread is not one of the cooperative pool's.
    private static func serve(
        server: DaemonSocketServer,
        idleTimeoutMs: Int,
        routing: Routing
    ) async {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                server.serve(idleTimeoutMs: idleTimeoutMs) { request in
                    let router = routing.router
                    return blocking { await router.reply(to: request) }
                }
                continuation.resume()
            }
            thread.name = "simprobe-daemon.socket"
            thread.start()
        }
    }

    /// Which router the socket thread should use, swapped once the companion is reachable.
    ///
    /// A lock rather than an actor: it is read on the socket thread, which is not part of the
    /// cooperative pool and cannot `await` anything.
    private final class Routing: @unchecked Sendable {

        private let lock = NSLock()
        private var current: DaemonRouter

        init(_ router: DaemonRouter) {
            current = router
        }

        var router: DaemonRouter {
            lock.lock()
            defer { lock.unlock() }
            return current
        }

        func adopt(_ router: DaemonRouter) {
            lock.lock()
            current = router
            lock.unlock()
        }
    }

    /// Runs an async call from a non-cooperative thread and waits for it.
    private static func blocking(_ body: @escaping @Sendable () async -> DaemonReply) -> DaemonReply
    {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box<DaemonReply>()
        Task {
            box.value = await body()
            semaphore.signal()
        }
        semaphore.wait()
        // Set before `signal()`, read after `wait()`: the semaphore is the ordering. The
        // fallback is unreachable and is a reply rather than a crash anyway — a daemon that
        // traps takes the caller's whole session with it.
        return box.value
            ?? DaemonReply(
                response: .failure(
                    .idbFailed(command: "daemon", detail: "the call produced no reply"))
            )
    }

    private final class Box<R>: @unchecked Sendable {
        var value: R?
    }

    /// Makes sure `idb_companion` is listening, running `idb connect` when it is not.
    ///
    /// On a thread of its own: it blocks for up to twenty-five seconds, and the cooperative pool
    /// is where the socket thread's replies are executed.
    private static func waitForCompanion(udid: String, log: DaemonLog) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                do {
                    try ensureCompanion(udid: udid, log: log)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            thread.name = "simprobe-daemon.connect"
            thread.start()
        }
    }

    private static func ensureCompanion(udid: String, log: DaemonLog) throws {
        let socket = IdbCompanionActor.companionSocket(udid: udid)
        guard !FileManager.default.fileExists(atPath: socket) else { return }
        let idb = try Idb.locate()
        log.write("idb-connect", ["udid": udid, "reason": "no companion socket"])
        _ = try? SystemProcessRunner().run(idb, ["connect", udid], deadlineMs: companionWaitMs)
        var waited = 0
        while !FileManager.default.fileExists(atPath: socket), waited < companionWaitMs {
            Thread.sleep(forTimeInterval: Double(companionPollMs) / 1_000)
            waited += companionPollMs
        }
        guard FileManager.default.fileExists(atPath: socket) else {
            throw ProbeError.idbFailed(
                command: "connect \(udid)",
                detail: "no companion socket at \(socket) after \(companionWaitMs)ms"
            )
        }
    }

    private static func executablePath() -> String {
        ProcessIdentity.executablePath(of: ProcessInfo.processInfo.processIdentifier)
            ?? CommandLine.arguments.first ?? "simprobe-daemon"
    }
}
