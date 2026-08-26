import Foundation

/// What a finished child process left behind.
public struct ProcessResult: Equatable, Sendable {
    public let status: Int32
    public let standardOutput: Data
    public let standardError: String

    public init(status: Int32, standardOutput: Data, standardError: String) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    /// Standard output decoded as UTF-8, empty when it is not valid UTF-8.
    public var standardOutputText: String {
        String(data: standardOutput, encoding: .utf8) ?? ""
    }

    /// The trimmed stderr, or a stand-in, for use in an error message.
    public var failureDetail: String {
        let trimmed = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "exit status \(status)" : trimmed
    }
}

/// Spawning a child process, behind a protocol so every adapter above it is testable.
public protocol ProcessRunning {
    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult
}

/// The real thing: `Process`, with both streams redirected to temporary files.
///
/// Files rather than `Pipe`s on purpose. `simctl list devices --json` easily exceeds the 64 KB
/// pipe buffer, and a reader that waits on the process before draining the pipe deadlocks at
/// exactly that size. Files have no buffer limit and need no second thread.
public struct SystemProcessRunner: ProcessRunning {

    public init() {}

    public func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        try TemporaryDirectory.withOne { directory in
            let outURL = directory.appendingPathComponent("stdout")
            let errURL = directory.appendingPathComponent("stderr")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = try makeHandle(at: outURL)
            process.standardError = try makeHandle(at: errURL)
            do {
                try process.run()
            } catch {
                throw ProbeError.simctlUnavailable("\(executable): \(error.localizedDescription)")
            }
            process.waitUntilExit()
            return ProcessResult(
                status: process.terminationStatus,
                standardOutput: (try? Data(contentsOf: outURL)) ?? Data(),
                standardError: (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            )
        }
    }

    private func makeHandle(at url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ProbeError.captureFailed("could not create \(url.lastPathComponent) buffer")
        }
        return try FileHandle(forWritingTo: url)
    }
}
