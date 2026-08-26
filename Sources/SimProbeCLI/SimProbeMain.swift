import ArgumentParser
import Foundation

/// The executable's entry point.
///
/// Not `SimProbe.main()`, because ArgumentParser exits 64 (`EX_USAGE`) for a bad flag while the
/// architecture's table says a usage error is exit 1. Everything else about ArgumentParser's
/// behaviour — `--help` and `--version` on stdout with status 0, diagnostics on stderr — is
/// kept exactly as it is.
public enum SimProbeMain {

    /// ArgumentParser's usage status, which this CLI remaps to 1.
    private static let usageStatus: Int32 = 64

    public static func run() -> Never {
        do {
            var command = try SimProbe.parseAsRoot()
            try command.run()
        } catch {
            emit(error)
            exit(processStatus(for: error))
        }
        exit(0)
    }

    /// The status a thrown error becomes. Exposed so the mapping can be asserted directly.
    static func processStatus(for error: any Error) -> Int32 {
        let status = SimProbe.exitCode(for: error).rawValue
        return status == usageStatus ? 1 : status
    }

    private static func emit(_ error: any Error) {
        let message = SimProbe.fullMessage(for: error)
        guard !message.isEmpty else { return }
        let stream =
            SimProbe.exitCode(for: error) == .success
            ? FileHandle.standardOutput : FileHandle.standardError
        stream.write(Data((message + "\n").utf8))
    }
}
