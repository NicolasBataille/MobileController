import CoreGraphics
import Foundation
import SimProbeCore

/// What `motion` was asked to do.
public struct MotionOptions: Equatable, Sendable {

    public let udid: String
    public let durationMs: Int
    public let tolerance: Double

    /// When set, one PNG per sample is written here. Nothing is written otherwise.
    public let keepFramesDirectory: URL?

    public let json: Bool

    public init(
        udid: String,
        durationMs: Int,
        tolerance: Double = FrameDiff.defaultTolerance,
        keepFramesDirectory: URL? = nil,
        json: Bool = false
    ) {
        self.udid = udid
        self.durationMs = durationMs
        self.tolerance = tolerance
        self.keepFramesDirectory = keepFramesDirectory
        self.json = json
    }
}

/// Records how much a screen changed over a window, as a text timeline.
///
/// The window starts once a baseline frame exists, because a diff needs two frames: the first
/// capture establishes the reference and is not itself a sample. Every timestamp is the one
/// the capture actually completed at — `simctl` costs roughly 200 ms per screenshot, so a
/// timeline built from requested intervals would be a fiction.
public struct MotionRunner {

    private let options: MotionOptions

    public init(options: MotionOptions) {
        self.options = options
    }

    public func run(in environment: ProbeEnvironment) throws -> Int32 {
        let directory = try prepareFrameDirectory()
        let timeline = MotionTimeline(
            samples: try sample(in: environment, writingTo: directory),
            tolerance: options.tolerance
        )
        environment.output.writeLine(
            options.json
                ? String(decoding: try timeline.jsonEncoded(), as: UTF8.self)
                : timeline.formatted()
        )
        return 0
    }

    private func sample(in environment: ProbeEnvironment, writingTo directory: URL?) throws
        -> [TimelineSample]
    {
        var previous = try Frames.thumbnail(
            of: environment.capture.capture(
                udid: options.udid,
                deadlineMs: ProcessDeadline.forCapture(remainingMs: options.durationMs)
            )
        )
        let startedAtMs = environment.clock.nowMs
        var samples: [TimelineSample] = []
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
                let name = Self.frameName(samples.count - 1, elapsedMs)
                try ImageEncoder.writePNG(image, to: directory.appendingPathComponent(name))
            }
            previous = frame
            if elapsedMs >= options.durationMs { return samples }
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
