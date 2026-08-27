/// Namespace for library-wide constants.
///
/// `SimProbeCore` is a pure library: no process spawning, no file IO, no clock reads.
/// Everything a function needs arrives as a parameter.
public enum SimProbeCore {
    /// Version of the library, reported by `simprobe --version`.
    public static let version = "0.3.0"
}
