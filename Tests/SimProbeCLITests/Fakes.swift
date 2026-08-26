import CoreGraphics
import Foundation

@testable import SimProbeCLI

/// Hands back a fixed frame sequence, so a poll loop's behaviour is a property of the loop and
/// not of whatever the simulator happened to be showing.
final class ScriptedCapture: ScreenCapturing {

    private let frames: [CGImage]
    private let clock: VirtualClock?
    private let costMs: Int

    private(set) var captureCount = 0
    private(set) var requestedUdids: [String] = []

    /// Set to make every capture fail instead of returning a frame.
    var failure: ProbeError?

    /// - Parameters:
    ///   - clock: advanced by `costMs` on each capture, modelling the ~200 ms `simctl` floor.
    init(frames: [CGImage], advancing clock: VirtualClock? = nil, costMs: Int = 0) {
        self.frames = frames
        self.clock = clock
        self.costMs = costMs
    }

    func capture(udid: String, deadlineMs: Int) throws -> CGImage {
        requestedUdids.append(udid)
        if let failure { throw failure }
        clock?.sleep(ms: costMs)
        guard captureCount < frames.count else {
            throw ProbeError.captureFailed("scripted capture exhausted after \(captureCount)")
        }
        defer { captureCount += 1 }
        return frames[captureCount]
    }
}

/// Models a `simctl` that has wedged: it consumes the whole deadline it was handed, then fails
/// the way `SystemProcessRunner` does once it has killed the child.
final class HangingCapture: ScreenCapturing {

    private let clock: VirtualClock

    /// The deadline each capture was given, which is what bounds the caller's wall time.
    private(set) var deadlines: [Int] = []

    init(advancing clock: VirtualClock) { self.clock = clock }

    func capture(udid: String, deadlineMs: Int) throws -> CGImage {
        deadlines.append(deadlineMs)
        clock.sleep(ms: deadlineMs)
        throw ProbeError.simctlFailed(
            command: "io \(udid) screenshot",
            detail: "timed out after \(deadlineMs)ms"
        )
    }
}

/// A clock that only moves when something asks it to sleep.
final class VirtualClock: ProbeClock {

    private(set) var nowMs: Int
    private(set) var sleeps: [Int] = []

    init(startMs: Int = 0) {
        nowMs = startMs
    }

    func sleep(ms: Int) {
        guard ms > 0 else { return }
        nowMs += ms
        sleeps.append(ms)
    }
}

/// Returns a canned device list.
struct StubDeviceLister: DeviceListing {
    let result: Result<[SimulatorDevice], ProbeError>

    init(_ devices: [SimulatorDevice]) { result = .success(devices) }
    init(failing error: ProbeError) { result = .failure(error) }

    func devices() throws -> [SimulatorDevice] { try result.get() }
}

/// Returns a canned process result without spawning anything.
final class StubProcessRunner: ProcessRunning {

    private let result: ProcessResult
    private(set) var invocations: [(executable: String, arguments: [String], deadlineMs: Int)] =
        []

    init(result: ProcessResult) { self.result = result }

    convenience init(standardOutput: String) {
        self.init(
            result: ProcessResult(
                status: 0,
                standardOutput: Data(standardOutput.utf8),
                standardError: ""
            )
        )
    }

    func run(_ executable: String, _ arguments: [String], deadlineMs: Int) throws
        -> ProcessResult
    {
        invocations.append((executable, arguments, deadlineMs))
        return result
    }
}

/// Collects what a command wrote, so a test can assert stdout and stderr separately.
final class RecordingOutput: OutputWriting {

    private(set) var outLines: [String] = []
    private(set) var errorLines: [String] = []

    func writeLine(_ text: String) { outLines.append(text) }
    func writeErrorLine(_ text: String) { errorLines.append(text) }

    var out: String { outLines.joined(separator: "\n") }
    var errorText: String { errorLines.joined(separator: "\n") }
}
