import CoreGraphics
import SimProbeCore

/// Bridges `SimProbeCore`'s frame maths into the CLI's error surface.
///
/// The core throws `FrameError`, which knows nothing about exit codes. Every crossing goes
/// through here so that a size mismatch reaches the shell as exit 5 rather than as a trap.
enum Frames {

    static func thumbnail(of image: CGImage) throws -> GrayFrame {
        do {
            return try Thumbnail.downscale(image)
        } catch {
            throw ProbeError.frameFailure(String(describing: error))
        }
    }

    static func observe(
        _ evaluator: StabilityEvaluator,
        _ frame: GrayFrame,
        atMs ms: Int
    ) throws -> StabilityEvaluator {
        do {
            return try evaluator.observing(frame, atMs: ms)
        } catch {
            throw ProbeError.frameFailure(String(describing: error))
        }
    }

    static func difference(_ lhs: GrayFrame, _ rhs: GrayFrame) throws -> Double {
        do {
            return try FrameDiff.meanAbsoluteDifference(lhs, rhs)
        } catch {
            throw ProbeError.frameFailure(String(describing: error))
        }
    }
}
