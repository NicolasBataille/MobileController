import CoreGraphics
import Foundation
import ImageIO
import SimProbeCore
import XCTest

@testable import SimProbeCLI

/// `shot` against a synthetic 1206x2622 framebuffer at 3x, the shape of a current iPhone.
final class ShotCommandTests: XCTestCase {

    private let sourceWidth = 1_206
    private let sourceHeight = 2_622

    func testDefaultWidthIsLogicalPointWidth() throws {
        let result = try runShot()

        XCTAssertEqual(result.code, 0)
        let written = try ImageDecoder.decode(contentsOf: result.path)
        XCTAssertEqual(written.width, 402)
        XCTAssertEqual(written.height, 874)
    }

    func testEncodesJPEGAtRequestedQuality() throws {
        let high = try runShot(quality: 90)
        let low = try runShot(quality: 20)

        XCTAssertEqual(try imageType(of: high.path), "public.jpeg")
        XCTAssertEqual(try imageType(of: low.path), "public.jpeg")
        XCTAssertLessThan(try byteCount(of: low.path), try byteCount(of: high.path))
    }

    func testSummaryLineReportsPixelSizeScaleBytesAndTokenEstimate() throws {
        let result = try runShot()

        let line = result.output.out
        XCTAssertTrue(line.hasPrefix(result.path.path), line)
        XCTAssertTrue(line.contains("402x874 @1x"), line)
        XCTAssertTrue(line.contains("jpeg q70"), line)
        XCTAssertTrue(line.contains(" KB "), line)
        // 468 is this fixture's number and nothing more general: 402 * 874 points over 750
        // pixels per vision token. A 420x912 screen (iPhone Air) costs 510 the same way.
        XCTAssertTrue(line.contains("~468 vision tokens"), line)
        XCTAssertTrue(line.contains("(source 1206x2622, 3.0x)"), line)
    }

    func testRejectsWidthLargerThanSourcePixelWidth() throws {
        XCTAssertThrowsError(try runShot(targetWidth: 2_000)) { error in
            XCTAssertEqual((error as? ProbeError)?.exitCode, 1)
            XCTAssertTrue("\(error)".contains("1206"), "\(error)")
        }
    }

    func testDerivesScaleFromSimctlEnumerate() throws {
        let runner = StubProcessRunner(standardOutput: EnumerateFixture.iPhoneAtThreeX)
        let metrics = SimctlDisplayMetrics(simctl: "/usr/bin/true", runner: runner)

        XCTAssertEqual(try metrics.scale(udid: Fixtures.udid), 3)
        XCTAssertEqual(runner.invocations.first?.arguments, ["io", Fixtures.udid, "enumerate"])
    }

    /// A quality outside 1...100 is a usage error, not something to silently clamp.
    ///
    /// Clamping answers `--quality 0` with a q1 JPEG and `--quality 1000` with a q100 one,
    /// both reported as the number that was asked for, so the summary line lies about what
    /// was written.
    func testRejectsQualityOutsideOneToOneHundred() throws {
        for quality in [0, -5, 101] {
            XCTAssertThrowsError(try runShot(quality: quality), "\(quality)") { error in
                XCTAssertEqual((error as? ProbeError)?.exitCode, 1, "\(quality)")
                XCTAssertTrue("\(error)".contains("1-100"), "\(error)")
            }
        }
        XCTAssertEqual(try runShot(quality: 1).code, 0)
        XCTAssertEqual(try runShot(quality: 100).code, 0)
    }

    /// A scale outside 0.5...16 is a usage error, not something to compute with.
    ///
    /// The pixel maths divides the framebuffer size by the scale, so a tiny positive value
    /// such as `1e-300` produces a point width no `Int` can hold and the conversion traps -
    /// the process dies on SIGTRAP (exit 133) with nothing printed. No simulator has ever
    /// reported a scale outside this range.
    func testRejectsScaleOutsideSaneRange() throws {
        for scale in [1e-300, 0.4, 0, -3, 16.5, 1e300] {
            XCTAssertThrowsError(try runShot(scale: scale), "\(scale)") { error in
                XCTAssertEqual((error as? ProbeError)?.exitCode, 1, "\(scale)")
                XCTAssertTrue("\(error)".contains("0.5"), "\(error)")
            }
        }
        // Both bounds are themselves usable. At 0.5 the point size is wider than the
        // framebuffer, so a target width is needed for the encode to be a downscale.
        XCTAssertEqual(try runShot(targetWidth: 1_000, scale: 0.5).code, 0)
        XCTAssertEqual(try runShot(scale: 16).code, 0)
    }

    /// The same bound applies to a scale that came from `simctl`, not from `--scale`.
    ///
    /// It is exit 2 rather than 1 there: nothing the caller typed is wrong, the environment
    /// described a screen `shot` cannot measure.
    func testEnumerateScaleOutsideRangeIsAnError() {
        let runner = StubProcessRunner(
            standardOutput: EnumerateFixture.iPhoneAtThreeX.replacingOccurrences(
                of: "Preferred UI Scale: 3",
                with: "Preferred UI Scale: 1e-300"
            )
        )
        let metrics = SimctlDisplayMetrics(simctl: "/usr/bin/true", runner: runner)

        XCTAssertThrowsError(try metrics.scale(udid: Fixtures.udid)) { error in
            XCTAssertEqual((error as? ProbeError)?.exitCode, 2, "\(error)")
        }
    }

    func testRejectsEnumerateOutputWithoutAnIntegratedScreen() {
        let runner = StubProcessRunner(standardOutput: "Port:\n    Class: Unknown\n")
        let metrics = SimctlDisplayMetrics(simctl: "/usr/bin/true", runner: runner)

        XCTAssertThrowsError(try metrics.scale(udid: Fixtures.udid)) { error in
            XCTAssertEqual((error as? ProbeError)?.exitCode, 2)
        }
    }

    // MARK: Harness

    private struct ShotResult {
        let code: Int32
        let output: RecordingOutput
        let path: URL
    }

    @discardableResult
    private func runShot(
        quality: Int = 70,
        targetWidth: Int? = nil,
        scale: Double = 3.0
    ) throws -> ShotResult {
        let output = RecordingOutput()
        let path = temporaryFile()
        let capture = ScriptedCapture(frames: [
            try TestFrames.gray(width: sourceWidth, height: sourceHeight) { x, y in
                UInt8((x / 8 + y / 8) % 256)
            }
        ])
        let options = ShotOptions(
            udid: Fixtures.udid,
            outputPath: path,
            scale: scale,
            targetWidth: targetWidth,
            quality: quality
        )
        let code = try ShotRunner(options: options)
            .run(in: ProbeEnvironment(capture: capture, clock: VirtualClock(), output: output))
        return ShotResult(code: code, output: output, path: path)
    }

    private func temporaryFile() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("simprobe-shot-\(UUID().uuidString).jpg")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func byteCount(of url: URL) throws -> Int {
        try Data(contentsOf: url).count
    }

    private func imageType(of url: URL) throws -> String {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceGetType(source)) as String
    }
}

/// A trimmed, anonymised `simctl io <udid> enumerate`. Every port UUID from the real output is
/// dropped: the parser never reads them, and a UDID-shaped string does not belong in a tracked
/// file.
enum EnumerateFixture {
    static let iPhoneAtThreeX = """
        Port:
            Class: Display
            Port Identifier: com.apple.framebuffer.display
            Display class: 0
            Default width: 1206
            Default height: 2622
        Port:
            Class: DisplayAdapter
            Port Identifier: com.apple.framebuffer.server
            Creatable Screen Properties:
            (101) CarPlay:
                Screen ID: 101
                Name: CarPlay
                Screen Type: CarPlay
                Pixel Size: {720, 480}
                Preferred UI Scale: 1
            Connected Screens:
            (1) LCD:
                Screen ID: 1
                Name: LCD
                Screen Type: Integrated
                Pixel Size: {1206, 2622}
                Preferred UI Scale: 3
            (2) TVOut:
                Screen ID: 2
                Name: TVOut
                Screen Type: TVOut
                Pixel Size: {720, 480}
                Preferred UI Scale: 1
        """
}
