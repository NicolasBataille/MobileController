/// Every way a `simprobe` invocation can fail, with the exit code it maps to.
///
/// The exit-code table is the CLI's contract with the shell (`02-architecture.md` §5), so it
/// lives on the error type itself rather than being reconstructed at each call site:
///
/// | Code | Meaning |
/// |---:|---|
/// | 1 | Usage / invalid arguments |
/// | 2 | Environment: `simctl` or `idb` missing or failing, no booted simulator, ambiguous UDID |
/// | 5 | Capture or decode failure |
///
/// Codes 3 (`wait-stable` timed out) and 4 (`diff` exceeded tolerance) are deliberately absent:
/// they are *results*, printed on stdout like any other result, not errors.
public enum ProbeError: Error, Equatable, Sendable {

    /// An argument was syntactically valid but meaningless, e.g. a negative duration.
    case invalidArgument(String)

    /// `simctl` could not be located; without it nothing else can run.
    case simctlUnavailable(String)

    /// `simctl` ran and reported a failure.
    case simctlFailed(command: String, detail: String)

    /// No simulator is booted, so there is nothing to resolve an omitted `--udid` to.
    case noBootedDevice

    /// More than one device answers to what was asked for; guessing would be worse than
    /// stopping, because acting on the wrong simulator is silent and expensive.
    case ambiguousDevice(requested: String?, candidates: [SimulatorDevice])

    /// Nothing on this machine matches the requested name or UDID.
    case deviceNotFound(String)

    /// A screenshot could not be taken or the resulting file could not be decoded.
    case captureFailed(String)

    /// A frame operation from `SimProbeCore` failed, e.g. two frames of different sizes.
    case frameFailure(String)

    /// A file the user named is not a decodable image.
    case imageUnreadable(String)

    /// An external tool a verb needs is not installed. Carries the command that installs it,
    /// because "install idb" without the incantation is a search the caller should not have
    /// to run.
    case dependencyMissing(tool: String, hint: String)

    /// `idb` ran and reported a failure, or answered with something unparseable.
    case idbFailed(command: String, detail: String)

    /// The process exit status this error produces.
    public var exitCode: Int32 {
        switch self {
        case .invalidArgument:
            return 1
        case .simctlUnavailable, .simctlFailed, .noBootedDevice, .ambiguousDevice,
            .deviceNotFound, .dependencyMissing, .idbFailed:
            return 2
        case .captureFailed, .frameFailure, .imageUnreadable:
            return 5
        }
    }

    /// A stable machine-readable discriminator, emitted as `error.kind` under `--json`.
    public var kind: String {
        switch self {
        case .invalidArgument: return "invalidArgument"
        case .simctlUnavailable: return "simctlUnavailable"
        case .simctlFailed: return "simctlFailed"
        case .noBootedDevice: return "noBootedDevice"
        case .ambiguousDevice: return "ambiguousDevice"
        case .deviceNotFound: return "deviceNotFound"
        case .captureFailed: return "captureFailed"
        case .frameFailure: return "frameFailure"
        case .imageUnreadable: return "imageUnreadable"
        case .dependencyMissing: return "dependencyMissing"
        case .idbFailed: return "idbFailed"
        }
    }
}

extension ProbeError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidArgument(let detail):
            return detail
        case .simctlUnavailable(let detail):
            return "simctl unavailable: \(detail)"
        case .simctlFailed(let command, let detail):
            return "simctl \(command) failed: \(detail)"
        case .noBootedDevice:
            return "no booted simulator; boot one or pass --udid"
        case .ambiguousDevice(let requested, let candidates):
            let subject =
                requested.map { "'\($0)' matches" } ?? "more than one simulator is booted:"
            return "\(subject) \(candidates.map(\.summary).joined(separator: ", ")); pass --udid"
        case .deviceNotFound(let requested):
            return "no simulator named or identified by '\(requested)'"
        case .captureFailed(let detail):
            return "capture failed: \(detail)"
        case .frameFailure(let detail):
            return "frame error: \(detail)"
        case .imageUnreadable(let path):
            return "could not read an image at \(path)"
        case .dependencyMissing(let tool, let hint):
            return "\(tool) is not installed; install it with: \(hint)"
        case .idbFailed(let command, let detail):
            return "idb \(command) failed: \(detail)"
        }
    }
}
