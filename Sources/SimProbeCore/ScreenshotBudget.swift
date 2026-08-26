/// Failures raised while planning a screenshot encode.
public enum ScreenshotBudgetError: Error, Equatable, Sendable {
    case invalidSourceSize(FrameSize)
    case invalidPointSize(FrameSize)
    case invalidTargetWidth(Int)

    /// Upscaling a screenshot adds bytes and vision tokens without adding information.
    case targetWidthExceedsSource(requested: Int, sourceWidth: Int)
}

extension ScreenshotBudgetError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidSourceSize(let size):
            return "invalid source pixel size \(size)"
        case .invalidPointSize(let size):
            return "invalid logical point size \(size)"
        case .invalidTargetWidth(let width):
            return "invalid target width \(width): must be positive"
        case .targetWidthExceedsSource(let requested, let sourceWidth):
            return "target width \(requested) exceeds the source width \(sourceWidth)"
        }
    }
}

/// What a screenshot will cost once encoded, decided before anything is encoded.
public struct EncodePlan: Equatable, Sendable {
    /// The framebuffer size as captured.
    public let sourcePixelSize: FrameSize

    /// The device's logical size, as reported alongside the capture.
    public let pointSize: FrameSize

    /// Framebuffer pixels per logical point, derived from the two sizes above.
    public let scale: Double

    /// The size the image will be encoded at.
    public let outputSize: FrameSize

    /// Estimated vision-token cost of the encoded image.
    public let estimatedVisionTokens: Int
}

/// Decides what size a screenshot should be encoded at, and what that will cost.
///
/// The default is 1x logical points, which is the entire point of the verb: a coordinate read
/// off the image maps 1:1 onto the accessibility frame, so an agent can act on what it sees
/// without a conversion step. It is also roughly a ninth of the tokens of the raw 3x
/// framebuffer.
public enum ScreenshotBudget {

    /// Image pixels per vision token, the widely used approximation for this model family.
    public static let pixelsPerVisionToken = 750

    /// Plans an encode.
    ///
    /// The scale factor is **derived** from the two sizes rather than assumed to be 3: it is 3
    /// on current iPhone hardware but 2 on several iPads and older devices, and a hardcoded
    /// constant would silently mis-size every coordinate on those.
    ///
    /// - Parameters:
    ///   - sourcePixelSize: framebuffer size of the capture.
    ///   - pointSize: the device's logical point size.
    ///   - targetWidth: output width in pixels; defaults to `pointSize.width`, i.e. 1x.
    /// - Throws: `ScreenshotBudgetError`.
    public static func plan(
        sourcePixelSize: FrameSize,
        pointSize: FrameSize,
        targetWidth: Int? = nil
    ) throws -> EncodePlan {
        guard sourcePixelSize.isPositive else {
            throw ScreenshotBudgetError.invalidSourceSize(sourcePixelSize)
        }
        guard pointSize.isPositive else {
            throw ScreenshotBudgetError.invalidPointSize(pointSize)
        }
        let width = targetWidth ?? pointSize.width
        guard width > 0 else { throw ScreenshotBudgetError.invalidTargetWidth(width) }
        guard width <= sourcePixelSize.width else {
            throw ScreenshotBudgetError.targetWidthExceedsSource(
                requested: width,
                sourceWidth: sourcePixelSize.width
            )
        }

        let outputSize = FrameSize(width: width, height: proportionalHeight(width, of: pointSize))
        return EncodePlan(
            sourcePixelSize: sourcePixelSize,
            pointSize: pointSize,
            scale: Double(sourcePixelSize.width) / Double(pointSize.width),
            outputSize: outputSize,
            estimatedVisionTokens: outputSize.pixelCount / pixelsPerVisionToken
        )
    }

    private static func proportionalHeight(_ width: Int, of pointSize: FrameSize) -> Int {
        let ratio = Double(pointSize.height) / Double(pointSize.width)
        return max(1, Int((Double(width) * ratio).rounded()))
    }
}
