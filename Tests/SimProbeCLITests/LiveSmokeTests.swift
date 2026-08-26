import Foundation
import SimProbeCore
import XCTest

@testable import SimProbeCLI

/// The only tests here that touch a real simulator.
///
/// They are skipped unless `SIMPROBE_LIVE=1`, so CI stays green on a runner with nothing
/// booted (PRD A5). Nothing here boots, shuts down or otherwise mutates a device: they observe
/// whatever is already on screen. Set `SIMPROBE_LIVE_UDID` to pin one when several are booted;
/// without it the single booted device is resolved, and the run fails if that is ambiguous.
final class LiveSmokeTests: XCTestCase {

    /// A live capture must carry actual content.
    ///
    /// Every other measurement here would pass on a frame of solid black - a black screen is
    /// perfectly stable, diffs to 0.00 and encodes to a valid JPEG - so this is the assertion
    /// that makes the rest of the live suite mean anything.
    func testLiveCaptureIsNotBlank() throws {
        let context = try liveContext()

        let frame = try Frames.thumbnail(
            of: try SimctlScreenCapture(simctl: context.simctl).capture(udid: context.udid)
        )

        let distinct = Set(frame.pixels)
        XCTAssertGreaterThan(distinct.count, 8, "the capture carried \(distinct.count) tones")
        XCTAssertFalse(frame.pixels.allSatisfy { $0 == 0 }, "the capture decoded as solid black")
    }

    func testLiveWaitStableSettlesOnStaticHomeScreen() throws {
        let context = try liveContext()
        let output = RecordingOutput()

        // Generous next to the 4 s default: a capture costs 0.2-1.1 s depending on host load,
        // and a verdict needs four of them.
        let options = WaitStableOptions(udid: context.udid, timeoutMs: 20_000)
        let code = try WaitStableRunner(options: options).run(
            in: context.environment(output: output))

        XCTAssertEqual(code, 0, output.out)
        XCTAssertTrue(output.out.hasPrefix("stable after "), output.out)
        XCTAssertTrue(output.out.hasSuffix("tol 0.50)"), output.out)
    }

    func testLiveShotMatchesReportedPointSize() throws {
        let context = try liveContext()
        let output = RecordingOutput()
        let scale = try context.session.displayMetrics.scale(udid: context.udid)
        let captured = try SimctlScreenCapture(simctl: context.simctl).capture(udid: context.udid)
        let expectedPointWidth = Int((Double(captured.width) / scale).rounded())

        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("simprobe-live-\(UUID().uuidString).jpg")
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        let options = ShotOptions(udid: context.udid, outputPath: path, scale: scale)
        let code = try ShotRunner(options: options).run(in: context.environment(output: output))

        XCTAssertEqual(code, 0)
        let written = try ImageDecoder.decode(contentsOf: path)
        XCTAssertEqual(written.width, expectedPointWidth)
        XCTAssertTrue(output.out.contains("@1x"), output.out)
        // PRD A4: a standard iPhone frame stays inside 500 vision tokens at 1x.
        let tokens = written.width * written.height / ScreenshotBudget.pixelsPerVisionToken
        XCTAssertLessThanOrEqual(tokens, 500, output.out)
    }

    func testLiveDevicesListsAtLeastOneBootedDevice() throws {
        let context = try liveContext()
        let output = RecordingOutput()

        let code = try DevicesRunner(options: .init(bootedOnly: true))
            .run(listing: SimctlDeviceLister(simctl: context.simctl), to: output)

        XCTAssertEqual(code, 0)
        XCTAssertGreaterThanOrEqual(output.outLines.count, 2, output.out)
        XCTAssertTrue(output.outLines.dropLast().allSatisfy { $0.hasPrefix("BOOTED") }, output.out)
        XCTAssertTrue(output.outLines.last?.hasSuffix(" booted") == true, output.out)
    }

    // MARK: Harness

    private struct LiveContext {
        let simctl: String
        let session: ProbeSession
        let udid: String

        func environment(output: any OutputWriting) -> ProbeEnvironment {
            session.environment(output: output)
        }
    }

    private func liveContext() throws -> LiveContext {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["SIMPROBE_LIVE"] == "1",
            "set SIMPROBE_LIVE=1 with a booted simulator to run the live smoke tests"
        )
        let simctl = try Simctl.locate()
        let session = ProbeSession(simctl: simctl, listing: SimctlDeviceLister(simctl: simctl))
        let requested = environment["SIMPROBE_LIVE_UDID"]
        return LiveContext(simctl: simctl, session: session, udid: try session.udid(for: requested))
    }
}
