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
    private let scale = 3.0

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
        // 402 * 874 / 750 pixels per vision token, and well inside the 500-token budget.
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
        targetWidth: Int? = nil
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
