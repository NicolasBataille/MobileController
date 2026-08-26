/// Everything a verb needs from the outside world, in one injectable bundle.
///
/// Device *resolution* is deliberately not here: it happens once, above the verbs, so that a
/// runner is handed a UDID it can use rather than a policy it has to apply.
public struct ProbeEnvironment {

    public let capture: any ScreenCapturing
    public let clock: any ProbeClock
    public let output: any OutputWriting

    public init(capture: any ScreenCapturing, clock: any ProbeClock, output: any OutputWriting) {
        self.capture = capture
        self.clock = clock
        self.output = output
    }

    /// The real one: `simctl` screenshots, a monotonic clock, the process streams.
    public static func live(simctl: String, output: any OutputWriting = StandardOutput())
        -> ProbeEnvironment
    {
        ProbeEnvironment(
            capture: SimctlScreenCapture(simctl: simctl),
            clock: SystemClock(),
            output: output
        )
    }
}
