import ArgumentParser

/// Turns a verb's return code into the process's exit status.
enum CommandExit {

    /// Codes 3 (`wait-stable` timed out) and 4 (`diff` exceeded tolerance) are results, not
    /// errors: the result line has already been printed on stdout by the time this runs.
    static func finish(_ code: Int32) throws {
        guard code == 0 else { throw ExitCode(code) }
    }
}
