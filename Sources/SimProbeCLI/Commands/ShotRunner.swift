import CoreGraphics
import Foundation
import SimProbeCore

/// What `shot` was asked to do.
public struct ShotOptions: Equatable, Sendable {

    /// Default JPEG quality. High enough that text stays legible at 1x, low enough that the
    /// file is a fraction of a PNG of the same frame.
    public static let defaultQuality = 70

    public let udid: String
    public let outputPath: URL

    /// Framebuffer pixels per logical point, resolved before the verb runs.
    public let scale: Double

    /// Output width in pixels; `nil` means the device's logical point width, i.e. 1x.
    public let targetWidth: Int?

    public let quality: Int
    public let json: Bool

    public init(
        udid: String,
        outputPath: URL,
        scale: Double,
        targetWidth: Int? = nil,
        quality: Int = ShotOptions.defaultQuality,
        json: Bool = false
    ) {
        self.udid = udid
        self.outputPath = outputPath
        self.scale = scale
        self.targetWidth = targetWidth
        self.quality = quality
        self.json = json
    }
}

/// Writes one screenshot at 1x logical points and reports what it cost.
///
/// 1x is the whole point of the verb: a coordinate read off the image maps 1:1 onto the
/// accessibility frame, so an agent can act on what it sees with no conversion step. It is
/// also roughly a ninth of the vision tokens of the raw 3x framebuffer.
public struct ShotRunner {

    private let options: ShotOptions

    public init(options: ShotOptions) {
        self.options = options
    }

    public func run(in environment: ProbeEnvironment) throws -> Int32 {
        let image = try environment.capture.capture(udid: options.udid)
        let plan = try plan(for: image)
        try ImageEncoder.writeJPEG(
            try ImageEncoder.resize(image, to: plan.outputSize),
            to: options.outputPath,
            quality: options.quality
        )
        let bytes = try byteCount()
        environment.output.writeLine(
            options.json ? try jsonLine(plan, bytes: bytes) : humanLine(plan, bytes: bytes)
        )
        return 0
    }

    private func plan(for image: CGImage) throws -> EncodePlan {
        guard options.scale > 0 else {
            throw ProbeError.invalidArgument("scale must be positive, got \(options.scale)")
        }
        let pixelSize = FrameSize(width: image.width, height: image.height)
        let pointSize = FrameSize(
            width: Int((Double(pixelSize.width) / options.scale).rounded()),
            height: Int((Double(pixelSize.height) / options.scale).rounded())
        )
        do {
            return try ScreenshotBudget.plan(
                sourcePixelSize: pixelSize,
                pointSize: pointSize,
                targetWidth: options.targetWidth
            )
        } catch let error as ScreenshotBudgetError {
            throw ProbeError.invalidArgument(error.description)
        }
    }

    private func byteCount() throws -> Int {
        guard
            let size = try? FileManager.default
                .attributesOfItem(atPath: options.outputPath.path)[.size] as? Int
        else {
            throw ProbeError.captureFailed("could not measure \(options.outputPath.path)")
        }
        return size
    }

    private func humanLine(_ plan: EncodePlan, bytes: Int) -> String {
        let outputScale = Double(plan.outputSize.width) / Double(plan.pointSize.width)
        return options.outputPath.path
            + String(
                format: "  %@ @%gx  jpeg q%d  %.1f KB  ~%d vision tokens  (source %@, %.1fx)",
                plan.outputSize.description,
                outputScale,
                options.quality,
                Double(bytes) / 1_024,
                plan.estimatedVisionTokens,
                plan.sourcePixelSize.description,
                plan.scale
            )
    }

    private func jsonLine(_ plan: EncodePlan, bytes: Int) throws -> String {
        try JSONLine.encode(
            Report(
                path: options.outputPath.path,
                width: plan.outputSize.width,
                height: plan.outputSize.height,
                sourceWidth: plan.sourcePixelSize.width,
                sourceHeight: plan.sourcePixelSize.height,
                scale: plan.scale,
                quality: options.quality,
                bytes: bytes,
                estimatedVisionTokens: plan.estimatedVisionTokens,
                udid: options.udid
            )
        )
    }

    private struct Report: Encodable {
        let path: String
        let width: Int
        let height: Int
        let sourceWidth: Int
        let sourceHeight: Int
        let scale: Double
        let quality: Int
        let bytes: Int
        let estimatedVisionTokens: Int
        let udid: String
    }
}
