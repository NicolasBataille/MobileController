/// Every way a `simprobe` invocation can fail, with the exit code it maps to.
///
/// The exit-code table is the CLI's contract with the shell (`02-architecture.md` §5), so it
/// lives on the error type itself rather than being reconstructed at each call site:
///
/// | Code | Meaning |
/// |---:|---|
/// | 1 | Usage / invalid arguments |
/// | 2 | Environment: `simctl` missing or failing, no booted simulator, ambiguous UDID |
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

    /// A screenshot could not be taken or the resulting file could not be decoded.
    case captureFailed(String)

    /// A frame operation from `SimProbeCore` failed, e.g. two frames of different sizes.
    case frameFailure(String)

    /// The process exit status this error produces.
    public var exitCode: Int32 {
        switch self {
        case .invalidArgument:
            return 1
        case .simctlUnavailable, .simctlFailed:
            return 2
        case .captureFailed, .frameFailure:
            return 5
        }
    }

    /// A stable machine-readable discriminator, emitted as `error.kind` under `--json`.
    public var kind: String {
        switch self {
        case .invalidArgument: return "invalidArgument"
        case .simctlUnavailable: return "simctlUnavailable"
        case .simctlFailed: return "simctlFailed"
        case .captureFailed: return "captureFailed"
        case .frameFailure: return "frameFailure"
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
        case .captureFailed(let detail):
            return "capture failed: \(detail)"
        case .frameFailure(let detail):
            return "frame error: \(detail)"
        }
    }
}
