import CoreGraphics
import Foundation
import ImageIO

/// Taking one screenshot of a simulator.
///
/// The only image-producing dependency in the CLI, so faking it is what lets every verb be
/// tested against a scripted frame sequence with no simulator involved.
public protocol ScreenCapturing {
    func capture(udid: String) throws -> CGImage
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

    public func capture(udid: String) throws -> CGImage {
        try TemporaryDirectory.withOne { directory in
            let file = directory.appendingPathComponent("frame.png")
            let result = try runner.run(simctl, ["io", udid, "screenshot", file.path])
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

    /// - Throws: `ProbeError.captureFailed` when the file is missing or not a decodable image.
    public static func decode(contentsOf url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            CGImageSourceGetCount(source) > 0,
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ProbeError.imageUnreadable(url.path)
        }
        return image
    }
}
