import Darwin
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import SimProbeCLI

/// The daemon's life: connect once, serve until told to stop or until nobody has asked in a
/// while, then leave nothing behind.
@available(macOS 15, *)
enum DaemonEntry {

    /// How long to wait for `idb connect` to produce a companion socket, polled.
    private static let companionWaitMs = 30_000
    private static let companionPollMs = 100

    static func run(_ arguments: DaemonArguments) async -> Int32 {
        let log = DaemonLog(path: arguments.logPath)
        log.write("starting", ["udid": arguments.udid, "socket": arguments.socketPath])
        do {
            try ensureCompanion(udid: arguments.udid, log: log)
            let server = try DaemonSocketServer(path: arguments.socketPath, log: log)
            try DaemonRecord(
                pid: ProcessInfo.processInfo.processIdentifier,
                udid: arguments.udid,
                executable: executablePath()
            ).write(to: arguments.pidFilePath)
            defer { try? FileManager.default.removeItem(atPath: arguments.pidFilePath) }
            try await serve(arguments, server: server, log: log)
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

    /// Holds one gRPC channel open for the whole serving loop.
    ///
    /// The socket loop is synchronous and runs on a thread of its own; the bridge back into the
    /// async world is one semaphore per request. A blocking wait is safe there precisely because
    /// that thread is not one of the cooperative pool's.
    private static func serve(
        _ arguments: DaemonArguments,
        server: DaemonSocketServer,
        log: DaemonLog
    ) async throws {
        try await withGRPCClient(
            transport: .http2NIOPosix(
                target: .unixDomainSocket(
                    path: IdbCompanionActor.companionSocket(udid: arguments.udid)),
                transportSecurity: .plaintext
            )
        ) { grpc in
            let actor = IdbCompanionActor(
                warm: IdbCompanionActor.CompanionClient(wrapping: grpc),
                udid: arguments.udid,
                log: log
            )
            let ticker = SystemTicker()
            let router = DaemonRouter(
                actor: actor,
                udid: arguments.udid,
                pid: ProcessInfo.processInfo.processIdentifier,
                ticker: ticker,
                startedAtMicroseconds: ticker.nowMicroseconds
            )
            log.write("ready")
            await withCheckedContinuation { continuation in
                let thread = Thread {
                    server.serve(idleTimeoutMs: arguments.idleTimeoutMs) { request in
                        blocking { await router.reply(to: request) }
                    }
                    continuation.resume()
                }
                thread.name = "simprobe-daemon.socket"
                thread.start()
            }
        }
    }

    /// Runs an async call from a non-cooperative thread and waits for it.
    private static func blocking<R: Sendable>(_ body: @escaping @Sendable () async -> R) -> R {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box<R>()
        Task {
            box.value = await body()
            semaphore.signal()
        }
        semaphore.wait()
        // Set before `signal()`, read after `wait()`: the semaphore is the ordering.
        return box.value!
    }

    private final class Box<R>: @unchecked Sendable {
        var value: R?
    }

    /// Makes sure `idb_companion` is listening, running `idb connect` when it is not.
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
