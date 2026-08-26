import Foundation

/// Where a command's text goes.
///
/// Results go to stdout and errors go to stderr, always separately: an agent parsing stdout
/// must never have to tell a result from a diagnostic by reading it.
public protocol OutputWriting: AnyObject {
    func writeLine(_ text: String)
    func writeErrorLine(_ text: String)
}

/// The process's own streams.
public final class StandardOutput: OutputWriting {

    public init() {}

    public func writeLine(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    public func writeErrorLine(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
