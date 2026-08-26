import Foundation
import SimProbeCore

/// What `diff` was asked to do.
public struct DiffOptions: Equatable, Sendable {
    public let lhs: URL
    public let rhs: URL
    public let tolerance: Double
    public let json: Bool

    public init(
        lhs: URL,
        rhs: URL,
        tolerance: Double = FrameDiff.defaultTolerance,
        json: Bool = false
    ) {
        self.lhs = lhs
        self.rhs = rhs
        self.tolerance = tolerance
        self.json = json
    }
}

/// Compares two image files the same way the live verbs compare two captures.
///
/// Both sides go through the same 40x87 grayscale thumbnail, so a `diff` of two saved
/// screenshots and a `wait-stable` on the live screen answer on one scale.
public struct DiffRunner {

    private let options: DiffOptions

    public init(options: DiffOptions) {
        self.options = options
    }

    /// - Returns: 0 when the two images are within tolerance, 4 when they are not, so that a
    ///   shell `&&` chain reads naturally.
    public func run(to output: any OutputWriting) throws -> Int32 {
        let before = try Frames.thumbnail(of: try ImageDecoder.decode(contentsOf: options.lhs))
        let after = try Frames.thumbnail(of: try ImageDecoder.decode(contentsOf: options.rhs))
        let difference = try Frames.difference(before, after)
        let same = difference <= options.tolerance
        output.writeLine(
            options.json
                ? try JSONLine.encode(
                    Report(
                        diff: difference,
                        tol: options.tolerance,
                        same: same,
                        size: before.size.description
                    )
                )
                : String(
                    format: "diff %.2f  (%@ gray, tol %.2f)  ->  %@",
                    difference,
                    before.size.description,
                    options.tolerance,
                    same ? "same" : "different"
                )
        )
        return same ? 0 : 4
    }

    private struct Report: Encodable {
        let diff: Double
        let tol: Double
        let same: Bool
        let size: String
    }
}
