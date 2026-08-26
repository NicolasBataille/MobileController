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

/// How long a child process is given before it is taken down.
public enum ProcessDeadline {

    /// The budget for a one-shot `simctl` call that has no deadline of its own.
    ///
    /// `list devices --json`, `io … enumerate` and a single screenshot each cost well under a
    /// second on an idle host and a few seconds on a loaded one. Fifteen seconds is therefore
    /// never reached by a call that is merely slow, and always reached by one that is wedged.
    public static let defaultMs = 15_000

    /// How long a child gets to exit after `SIGTERM` before it is sent `SIGKILL`.
    public static let terminationGraceMs = 500

    /// The smallest deadline a screenshot is ever given, whatever budget is left.
    ///
    /// One `simctl` screenshot costs 0.2-1.1 s, more on a loaded host. A poll loop whose own
    /// budget has nearly run out must still let the capture in flight finish: killing it would
    /// turn "the screen never settled" (a result, exit 3) into "simctl failed" (exit 2).
    public static let minimumCaptureMs = 2_000

    /// What is left of a poll loop's budget, but never less than one capture.
    ///
    /// This is what makes a verb's `--timeout` a bound on wall time rather than on polling
    /// alone: a `simctl` that never returns is killed at the deadline instead of pinning the
    /// process. The floor keeps a merely slow capture from being killed as the budget runs out.
    public static func forCapture(remainingMs: Int) -> Int {
        max(remainingMs, minimumCaptureMs)
    }
}

/// Spawning a child process, behind a protocol so every adapter above it is testable.
public protocol ProcessRunning {

    /// - Parameter deadlineMs: wall-clock budget. On expiry the child is terminated, then
    ///   killed, and `ProbeError.simctlFailed` is thrown.
    func run(_ executable: String, _ arguments: [String], deadlineMs: Int) throws -> ProcessResult
}

extension ProcessRunning {

    /// Runs with `ProcessDeadline.defaultMs`, for callers that carry no budget of their own.
    public func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        try run(executable, arguments, deadlineMs: ProcessDeadline.defaultMs)
    }
}

/// The real thing: `Process`, with both streams redirected to temporary files.
///
/// Files rather than `Pipe`s on purpose. `simctl list devices --json` easily exceeds the 64 KB
/// pipe buffer, and a reader that waits on the process before draining the pipe deadlocks at
/// exactly that size. Files have no buffer limit and need no second thread.
public struct SystemProcessRunner: ProcessRunning {

    public init() {}

    public func run(_ executable: String, _ arguments: [String], deadlineMs: Int) throws
        -> ProcessResult
    {
        try TemporaryDirectory.withOne { directory in
            let outURL = directory.appendingPathComponent("stdout")
            let errURL = directory.appendingPathComponent("stderr")
            let outHandle = try makeHandle(at: outURL)
            let errHandle = try makeHandle(at: errURL)
            let handles = [outHandle, errHandle]
            // The writing ends are closed again below, before the files are read, so the read
            // never races a buffered write. This is the failure-path guarantee.
            defer { for handle in handles { try? handle.close() } }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = outHandle
            process.standardError = errHandle
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            do {
                try process.run()
            } catch {
                throw ProbeError.simctlUnavailable("\(executable): \(error.localizedDescription)")
            }
            let exitedInTime = Self.wait(process, until: finished, deadlineMs: deadlineMs)
            for handle in handles { try? handle.close() }
            guard exitedInTime else {
                throw ProbeError.simctlFailed(
                    command: Self.label(executable, arguments),
                    detail: "timed out after \(deadlineMs)ms"
                )
            }
            return ProcessResult(
                status: process.terminationStatus,
                standardOutput: (try? Data(contentsOf: outURL)) ?? Data(),
                standardError: (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            )
        }
    }

    /// Waits for `process`, escalating on expiry: `SIGTERM`, a short grace, then `SIGKILL`.
    ///
    /// The final `waitUntilExit` is what reaps the child; without it a killed process would be
    /// left as a zombie for the lifetime of the CLI.
    ///
    /// - Returns: whether the child exited on its own before the deadline.
    private static func wait(_ process: Process, until finished: DispatchSemaphore, deadlineMs: Int)
        -> Bool
    {
        if finished.wait(timeout: .now() + .milliseconds(max(deadlineMs, 0))) == .success {
            process.waitUntilExit()
            return true
        }
        process.terminate()
        let grace = DispatchTime.now() + .milliseconds(ProcessDeadline.terminationGraceMs)
        if finished.wait(timeout: grace) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        return false
    }

    /// `simctl io <udid> screenshot …`: the executable's name plus its arguments, which is what
    /// a reader needs to recognise the call that hung.
    private static func label(_ executable: String, _ arguments: [String]) -> String {
        ([URL(fileURLWithPath: executable).lastPathComponent] + arguments).joined(separator: " ")
    }

    private func makeHandle(at url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ProbeError.captureFailed("could not create \(url.lastPathComponent) buffer")
        }
        return try FileHandle(forWritingTo: url)
    }
}
