import CoreGraphics
import Foundation
import ImageIO

/// Taking one screenshot of a simulator.
///
/// The only image-producing dependency in the CLI, so faking it is what lets every verb be
/// tested against a scripted frame sequence with no simulator involved.
public protocol ScreenCapturing {

    /// - Parameter deadlineMs: wall-clock budget for the capture. A poll loop passes what is
    ///   left of its own timeout, so a wedged `simctl` cannot outlive the verb that called it.
    func capture(udid: String, deadlineMs: Int) throws -> CGImage
}

extension ScreenCapturing {

    /// Captures with `ProcessDeadline.defaultMs`, for one-shot callers with no budget of
    /// their own.
    public func capture(udid: String) throws -> CGImage {
        try capture(udid: udid, deadlineMs: ProcessDeadline.defaultMs)
    }
}

/// Captures through `xcrun simctl io <udid> screenshot <file>`.
///
/// The file is mandatory: `simctl io … screenshot -` does **not** stream to stdout, it writes a
/// file literally named `-`. The capture therefore lands in a temporary directory that is
/// removed in a `defer`, and only the decoded `CGImage` escapes.
public struct SimctlScreenCapture: ScreenCapturing {

    private let simctl: String
    private let runner: any ProcessRunning

    public init(simctl: String, runner: any ProcessRunning = SystemProcessRunner()) {
        self.simctl = simctl
        self.runner = runner
    }

    public func capture(udid: String, deadlineMs: Int) throws -> CGImage {
        try TemporaryDirectory.withOne { directory in
            let file = directory.appendingPathComponent("frame.png")
            let result = try runner.run(
                simctl,
                ["io", udid, "screenshot", file.path],
                deadlineMs: deadlineMs
            )
            guard result.status == 0 else {
                throw ProbeError.captureFailed(
                    "simctl io \(udid) screenshot: \(result.failureDetail)"
                )
            }
            return try ImageDecoder.decode(contentsOf: file)
        }
    }
}

/// Reads an image file into a `CGImage`.
public enum ImageDecoder {

    /// Decodes from the file's **bytes**, never from the file itself.
    ///
    /// `CGImageSourceCreateWithURL` decodes lazily and the resulting `CGImage` keeps referring
    /// to the file on disk. A capture whose temporary directory is removed in a `defer` would
    /// then hand back an image that draws as solid black - every diff reads 0.00 and every
    /// screen looks settled, with nothing anywhere reporting a failure. Reading the bytes first
    /// binds the image to memory that outlives the file.
    ///
    /// - Throws: `ProbeError.imageUnreadable` when the file is missing or not a decodable image.
    public static func decode(contentsOf url: URL) throws -> CGImage {
        guard let data = try? Data(contentsOf: url),
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0,
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ProbeError.imageUnreadable(url.path)
        }
        return image
    }
}
