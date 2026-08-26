import CoreGraphics
import Foundation
import ImageIO
import SimProbeCore
import UniformTypeIdentifiers

/// Writes a `CGImage` to disk.
///
/// The only place in the CLI that produces image bytes, and nothing calls it unless the user
/// explicitly asked for a file (`motion --keep-frames`, `shot --out`).
enum ImageEncoder {

    static func writePNG(_ image: CGImage, to url: URL) throws {
        try write(image, to: url, type: UTType.png, properties: nil)
    }

    fileprivate static func write(
        _ image: CGImage,
        to url: URL,
        type: UTType,
        properties: CFDictionary?
    ) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                type.identifier as CFString,
                1,
                nil
            )
        else {
            throw ProbeError.captureFailed("could not open \(url.path) for writing")
        }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw ProbeError.captureFailed("could not encode \(url.lastPathComponent)")
        }
    }
}

extension ImageEncoder {

    /// The range `--quality` accepts. Zero is excluded: it is not a quality, it is a request
    /// for an unreadable image.
    static let qualityRange = 1...100

    /// - Parameter quality: 1-100, as the `--quality` flag states it.
    /// - Throws: `ProbeError.invalidArgument` (exit 1) outside that range. Clamping instead
    ///   would write a q1 or q100 file while the summary line reported the number that was
    ///   asked for, so the output would misdescribe the file it just wrote.
    static func writeJPEG(_ image: CGImage, to url: URL, quality: Int) throws {
        guard qualityRange.contains(quality) else {
            throw ProbeError.invalidArgument(
                "--quality must be 1-100, got \(quality)"
            )
        }
        try write(
            image,
            to: url,
            type: UTType.jpeg,
            properties: [
                kCGImageDestinationLossyCompressionQuality: Double(quality) / 100
            ] as CFDictionary
        )
    }

    /// Redraws `image` at `size`, in colour.
    static func resize(_ image: CGImage, to size: FrameSize) throws -> CGImage {
        guard
            let context = CGContext(
                data: nil,
                width: size.width,
                height: size.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else {
            throw ProbeError.captureFailed("could not create a \(size) bitmap context")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let resized = context.makeImage() else {
            throw ProbeError.captureFailed("could not resize the capture to \(size)")
        }
        return resized
    }
}
