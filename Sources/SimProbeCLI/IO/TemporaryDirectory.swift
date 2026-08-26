import Foundation

/// A scratch directory that always cleans itself up.
///
/// Two IO paths need one: `simctl io … screenshot -` writes a *file literally named `-`*
/// rather than streaming, so a capture must go through disk; and child-process output is
/// buffered through files to sidestep the pipe-buffer deadlock.
public enum TemporaryDirectory {

    /// Runs `body` with a fresh directory, removed in a `defer` whatever `body` does.
    public static func withOne<T>(_ body: (URL) throws -> T) throws -> T {
        let manager = FileManager.default
        let url = manager.temporaryDirectory
            .appendingPathComponent("simprobe-\(UUID().uuidString)", isDirectory: true)
        do {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw ProbeError.captureFailed(
                "could not create a temporary directory: \(error.localizedDescription)"
            )
        }
        defer { try? manager.removeItem(at: url) }
        return try body(url)
    }
}
