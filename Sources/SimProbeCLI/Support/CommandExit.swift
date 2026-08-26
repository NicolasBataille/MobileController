import ArgumentParser

/// Turns a verb's return code into the process's exit status, and its failures into the
/// documented exit codes with their message on the right stream.
enum CommandExit {

    /// Runs `body`, reports any `ProbeError` it raises, and exits with the documented status.
    ///
    /// Codes 3 (`wait-stable` timed out) and 4 (`diff` exceeded tolerance) arrive as a return
    /// value rather than as an error: they are results, and their result line has already been
    /// printed on stdout by the time this runs.
    static func reporting(
        json: Bool,
        to output: any OutputWriting = StandardOutput(),
        _ body: (any OutputWriting) throws -> Int32
    ) throws {
        do {
            let code = try body(output)
            guard code == 0 else { throw ExitCode(code) }
        } catch let error as ProbeError {
            ErrorReporter.report(error, json: json, to: output)
            throw ExitCode(error.exitCode)
        }
    }
}
