import Foundation
import XCTest

@testable import SimProbeCLI

/// `tree` is `frames` over a different transport, and the tests exist to keep it that way: what
/// is asserted here is that the daemon path produces the *same* output from the *same* payload.
final class TreeCommandTests: XCTestCase {

    func testPrintsWhatFramesPrintsFromTheSamePayload() throws {
        let viaDaemon = RecordingOutput()
        let viaIdb = RecordingOutput()
        let snapshot = try AccessibilityElementParser.parseAll(
            Data(ElementFixture.describeAll.utf8))

        _ = try FramesRunner(options: FramesOptions(udid: "UDID"))
            .run(describing: Self.describer(), to: viaDaemon)
        _ = try FramesRunner(options: FramesOptions(udid: "UDID"))
            .run(describing: StubElementDescriber(snapshot), to: viaIdb)

        XCTAssertEqual(viaDaemon.outLines, viaIdb.outLines)
        XCTAssertTrue(viaDaemon.outLines.first?.contains("402x874") == true, viaDaemon.out)
        XCTAssertTrue(viaDaemon.outLines.contains { $0.hasPrefix("[Content]") }, viaDaemon.out)
    }

    func testInteractiveKeepsOnlyWhatCanBeActedOn() throws {
        let output = RecordingOutput()

        _ = try FramesRunner(options: FramesOptions(udid: "UDID", interactiveOnly: true))
            .run(describing: Self.describer(), to: output)

        XCTAssertTrue(output.out.contains("#nav.back"), output.out)
        XCTAssertTrue(output.out.contains("#form.email"), output.out)
        // A disabled button is a control a caller would waste a turn pressing.
        XCTAssertFalse(output.out.contains("#form.submit"), output.out)
        XCTAssertFalse(output.out.contains("Logo"), output.out)
    }

    func testJSONIsOneLineOfElements() throws {
        let output = RecordingOutput()

        _ = try FramesRunner(options: FramesOptions(udid: "UDID", json: true))
            .run(describing: Self.describer(), to: output)

        XCTAssertEqual(output.outLines.count, 1)
        XCTAssertTrue(output.out.hasPrefix("["), output.out)
        XCTAssertTrue(output.out.contains(##""ref":"#nav.back""##), output.out)
    }

    /// The one place the daemon transport can fail differently from the CLI one: a response
    /// that arrived but carried nothing to parse.
    func testATreeResponseWithNoPayloadIsAnEnvironmentFailure() {
        let client = FakeDaemonClient(responses: [.tree: DaemonResponse(ok: true, ms: 70)])

        XCTAssertThrowsError(
            try DaemonElementDescriber(client: client).describeAll(udid: "UDID")
        ) { error in
            XCTAssertEqual((error as? ProbeError)?.exitCode, 2)
            XCTAssertTrue("\(error)".contains("no tree"), "\(error)")
        }
    }

    func testUnreadableJSONIsReportedRatherThanSilentlyEmpty() {
        let client = FakeDaemonClient(responses: [
            .tree: DaemonResponse(ok: true, treeJSON: "not json at all")
        ])

        XCTAssertThrowsError(
            try DaemonElementDescriber(client: client).describeAll(udid: "UDID")
        ) { error in
            XCTAssertEqual((error as? ProbeError)?.exitCode, 2)
        }
    }

    func testAMissingDaemonExitsTwoWithTheStartCommand() {
        XCTAssertThrowsError(
            try DaemonElementDescriber(client: FakeDaemonClient.absent()).describeAll(udid: "UDID")
        ) { error in
            XCTAssertEqual(error as? ProbeError, .daemonUnavailable(udid: "UDID"))
            XCTAssertTrue("\(error)".contains("simprobe daemon start --udid"), "\(error)")
        }
    }

    // MARK: - Local hit testing

    /// A point read off a screenshot resolves without a second round trip: the tree already
    /// carries every frame, and at 70 ms a tree the search is free by comparison.
    func testAPointResolvesToTheSmallestElementContainingIt() throws {
        let describer = Self.describer()

        let hit = try describer.element(atX: 30, y: 790, udid: "UDID")

        // The tab button, not the full-screen Group that also contains the point.
        XCTAssertEqual(hit?.ref, "#tab.explore")
    }

    func testAPointOutsideEverythingResolvesToNothing() throws {
        XCTAssertNil(try Self.describer().element(atX: 4_000, y: 4_000, udid: "UDID"))
    }

    func testFrameGeometryUsesHalfOpenEdges() {
        let frame = ElementFrame(x: 10, y: 20, width: 100, height: 40)

        XCTAssertTrue(frame.contains(x: 10, y: 20))
        XCTAssertFalse(frame.contains(x: 110, y: 20), "the right edge belongs to the next frame")
        XCTAssertFalse(frame.contains(x: 10, y: 60), "the bottom edge belongs to the next frame")
        XCTAssertEqual(frame.centre, ElementPoint(x: 60, y: 40))
        XCTAssertEqual(frame.area, 4_000)
    }

    private static func describer() -> DaemonElementDescriber {
        DaemonElementDescriber(
            client: FakeDaemonClient(responses: [
                .tree: DaemonResponse(ok: true, ms: 70, treeJSON: ElementFixture.describeAll)
            ])
        )
    }
}
