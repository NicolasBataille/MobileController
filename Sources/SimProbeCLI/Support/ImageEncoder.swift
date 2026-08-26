import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes a `CGImage` to disk.
///
/// The only place in the CLI that produces image bytes, and nothing calls it unless the user
/// explicitly asked for a file (`motion --keep-frames`, `shot --out`).
enum ImageEncoder {

    static func writePNG(_ image: CGImage, to url: URL) throws {
        try write(image, to: url, type: UTType.png, properties: nil)
    }

    private static func write(
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
