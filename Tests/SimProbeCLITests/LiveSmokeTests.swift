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
        // PRD A4: the 1x cost is a property of the screen, not a constant - 402x874 points
        // cost 468 vision tokens and 420x912 (iPhone Air) cost 510 - so what is asserted is
        // the formula against the file that was actually written, plus a rounding margin.
        let budget = written.width * written.height / ScreenshotBudget.pixelsPerVisionToken
        XCTAssertLessThanOrEqual(try reportedVisionTokens(in: output.out), budget + 8, output.out)
        // And 1x is still worth taking: the raw framebuffer is roughly nine times this.
        let rawTokens = captured.width * captured.height / ScreenshotBudget.pixelsPerVisionToken
        XCTAssertLessThan(budget * 4, rawTokens, output.out)
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

    /// `frames` against whatever is on screen.
    ///
    /// The only exercise the idb plumbing ever gets: the companion, the connect-and-retry
    /// path, and the real JSON shape, none of which a fixture can prove still hold. What is
    /// asserted is the property the verb exists for — that the frames are in the same logical
    /// points `shot` writes its image in, and not in framebuffer pixels.
    func testLiveFramesReportsPointSizedFrames() throws {
        let context = try liveContext()
        let idb = try idbPath()
        let scale = try context.session.displayMetrics.scale(udid: context.udid)
        let captured = try SimctlScreenCapture(simctl: context.simctl).capture(udid: context.udid)

        let snapshot = try IdbElementDescriber(idb: idb).describeAll(udid: context.udid)

        XCTAssertFalse(snapshot.elements.isEmpty, "nothing on screen has an accessibility frame")
        XCTAssertEqual(snapshot.screen.width, Int((Double(captured.width) / scale).rounded()))
        XCTAssertTrue(
            snapshot.elements.contains {
                !$0.frame.isEmpty && $0.frame.intersects(snapshot.screen)
            },
            "no element of the \(snapshot.elements.count) reported is on screen"
        )
    }

    func testLiveFramesPrintsABandedListWithASizedHeader() throws {
        let context = try liveContext()
        let idb = try idbPath()
        let output = RecordingOutput()

        let code = try FramesRunner(options: FramesOptions(udid: context.udid))
            .run(describing: IdbElementDescriber(idb: idb), to: output)

        XCTAssertEqual(code, 0)
        XCTAssertTrue(output.outLines.first?.contains("x") == true, output.out)
        XCTAssertTrue(output.outLines.contains { $0.hasPrefix("[") }, output.out)
        XCTAssertTrue(output.outLines.contains { $0.hasPrefix("  ") }, output.out)
    }

    // MARK: Harness

    private func idbPath() throws -> String {
        guard let idb = try? Idb.locate() else {
            throw XCTSkip("idb is not installed: \(Idb.installHint)")
        }
        return idb
    }

    /// The `~468 vision tokens` figure out of a `shot` summary line.
    private func reportedVisionTokens(in line: String) throws -> Int {
        let tail = try XCTUnwrap(line.components(separatedBy: "~").last, line)
        return try XCTUnwrap(Int(tail.prefix { $0.isNumber }), line)
    }

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
