import CoreGraphics
import Foundation
import SimProbeCore

/// What `motion` was asked to do.
public struct MotionOptions: Equatable, Sendable {

    /// How many PNGs `--keep-frames` will write before it stops.
    ///
    /// `--keep-frames` is the only path that writes images, it writes one per sample, and the
    /// directory is whatever the caller typed. A long window on a fast host therefore has
    /// nothing bounding what it leaves on disk. Ten thousand frames is far more than any
    /// transition worth inspecting and still bounded.
    public static let defaultKeepFramesCap = 10_000

    public let udid: String
    public let durationMs: Int
    public let tolerance: Double

    /// When set, one PNG per sample is written here. Nothing is written otherwise.
    public let keepFramesDirectory: URL?

    /// Upper bound on how many PNGs are written. Injectable so a test can reach the cap
    /// without writing ten thousand files.
    public let keepFramesCap: Int

    public let json: Bool

    public init(
        udid: String,
        durationMs: Int,
        tolerance: Double = FrameDiff.defaultTolerance,
        keepFramesDirectory: URL? = nil,
        keepFramesCap: Int = MotionOptions.defaultKeepFramesCap,
        json: Bool = false
    ) {
        self.udid = udid
        self.durationMs = durationMs
        self.tolerance = tolerance
        self.keepFramesDirectory = keepFramesDirectory
        self.keepFramesCap = keepFramesCap
        self.json = json
    }
}

/// Records how much a screen changed over a window, as a text timeline.
///
/// The window starts once a baseline frame exists, because a diff needs two frames: the first
/// capture establishes the reference and is not itself a sample. Every timestamp is the one
/// the capture actually completed at — `simctl` costs roughly 200 ms per screenshot, so a
/// timeline built from requested intervals would be a fiction.
///
/// `--keep-frames` writes at most `MotionOptions.keepFramesCap` PNGs. Sampling itself is never
/// capped: the timeline is the answer the verb owes its caller, the frames are an extra, so
/// hitting the cap stops the writing and is reported rather than ending the run early.
public struct MotionRunner {

    private let options: MotionOptions

    public init(options: MotionOptions) {
        self.options = options
    }

    public func run(in environment: ProbeEnvironment) throws -> Int32 {
        let directory = try prepareFrameDirectory()
        let capture = try sample(in: environment, writingTo: directory)
        let timeline = MotionTimeline(
            samples: capture.samples,
            tolerance: options.tolerance,
            framesCappedAt: capture.framesCappedAt
        )
        environment.output.writeLine(
            options.json
                ? String(decoding: try timeline.jsonEncoded(), as: UTF8.self)
                : timeline.formatted()
        )
        return 0
    }

    /// What one run measured: every sample, plus the cap if frame writing hit one.
    private struct Capture {
        let samples: [TimelineSample]
        let framesCappedAt: Int?
    }

    private func sample(in environment: ProbeEnvironment, writingTo directory: URL?) throws
        -> Capture
    {
        var previous = try Frames.thumbnail(
            of: environment.capture.capture(
                udid: options.udid,
                deadlineMs: ProcessDeadline.forCapture(remainingMs: options.durationMs)
            )
        )
        let startedAtMs = environment.clock.nowMs
        var samples: [TimelineSample] = []
        var framesWritten = 0
        var framesCapped = false
        while true {
            let image = try environment.capture.capture(
                udid: options.udid,
                deadlineMs: ProcessDeadline.forCapture(
                    remainingMs: options.durationMs - (environment.clock.nowMs - startedAtMs))
            )
            let elapsedMs = environment.clock.nowMs - startedAtMs
            let frame = try Frames.thumbnail(of: image)
            samples.append(
                TimelineSample(tMs: elapsedMs, diff: try Frames.difference(previous, frame))
            )
            if let directory {
                if framesWritten < options.keepFramesCap {
                    let name = Self.frameName(samples.count - 1, elapsedMs)
                    try ImageEncoder.writePNG(image, to: directory.appendingPathComponent(name))
                    framesWritten += 1
                } else {
                    framesCapped = true
                }
            }
            previous = frame
            if elapsedMs >= options.durationMs {
                return Capture(
                    samples: samples,
                    framesCappedAt: framesCapped ? options.keepFramesCap : nil
                )
            }
        }
    }

    /// `frame-000-205ms.png`: the sample index leads, zero-padded, and the timestamp follows.
    ///
    /// The index is what makes the name unique. Two captures can complete in the same
    /// millisecond on an idle host, and a name built from the timestamp alone silently
    /// overwrites the earlier frame - the one case where `--keep-frames` is asked for
    /// precisely because something moved fast.
    static func frameName(_ index: Int, _ elapsedMs: Int) -> String {
        String(format: "frame-%03d-%dms.png", index, elapsedMs)
    }

    private func prepareFrameDirectory() throws -> URL? {
        guard let directory = options.keepFramesDirectory else { return nil }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw ProbeError.invalidArgument(
                "could not use \(directory.path) for --keep-frames: \(error.localizedDescription)"
            )
        }
        return directory
    }
}
