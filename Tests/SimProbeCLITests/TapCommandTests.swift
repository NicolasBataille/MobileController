import Foundation
import XCTest

@testable import SimProbeCLI

/// `tap` is the only verb here that *changes* the device, so what it aims at is worth more
/// assertions than what it prints.
final class TapCommandTests: XCTestCase {

    // MARK: - Targets

    func testParsesTheThreeSpellingsFramesPrints() throws {
        XCTAssertEqual(try TapTarget.parse("#form.submit"), .identifier("form.submit"))
        XCTAssertEqual(try TapTarget.parse("@7"), .index(7))
        XCTAssertEqual(try TapTarget.parse("201,822"), .point(ElementPoint(x: 201, y: 822)))
    }

    func testRejectsAnythingElseRatherThanTappingSomewhere() {
        for text in ["", "#", "@", "@x", "@-1", "submit", "201;822", "201,822,3", "201,"] {
            XCTAssertThrowsError(try TapTarget.parse(text), text) { error in
                XCTAssertEqual((error as? ProbeError)?.exitCode, 1, text)
            }
        }
    }

    func testOnlyAnElementTargetNeedsATree() throws {
        XCTAssertTrue(try TapTarget.parse("#a").needsTree)
        XCTAssertTrue(try TapTarget.parse("@1").needsTree)
        XCTAssertFalse(try TapTarget.parse("1,2").needsTree)
    }

    // MARK: - Aiming

    func testTapsTheCentreOfTheElementFrame() throws {
        let output = try Self.tap("#tab.explore")

        // The fixture's frame is (22,781 119x44), whose centre is (81,803).
        XCTAssertEqual(output.client.operations, [.tree, .tap])
        XCTAssertEqual(output.client.requests.last?.x, 81)
        XCTAssertEqual(output.client.requests.last?.y, 803)
        XCTAssertEqual(output.recorded.out, "tapped #tab.explore (81,803) 1.0 ms")
    }

    func testResolvesAnIndexTheSameWayFramesPrintsIt() throws {
        let output = try Self.tap("@2")

        // `@2` is the heading at (16,120 147x41) after rounding: centre (89,140).
        XCTAssertEqual(output.client.requests.last?.x, 89)
        XCTAssertEqual(output.client.requests.last?.y, 140)
        XCTAssertTrue(output.recorded.out.hasPrefix("tapped @2 (89,140)"), output.recorded.out)
    }

    /// A coordinate target must not cost a tree read: that is the whole 70 ms difference
    /// between a blind tap and a resolved one.
    func testACoordinateTargetTapsWithoutReadingATree() throws {
        let output = try Self.tap("201,822")

        XCTAssertEqual(output.client.operations, [.tap])
        XCTAssertEqual(output.recorded.out, "tapped (201,822) 1.0 ms")
    }

    func testAnUnknownRefFailsWithoutTapping() throws {
        let client = FakeDaemonClient(responses: [
            .tree: DaemonResponse(ok: true, treeJSON: ElementFixture.describeAll)
        ])

        XCTAssertThrowsError(
            try TapRunner(options: TapOptions(udid: "UDID", target: .identifier("nope")))
                .run(through: client, in: Self.environment(RecordingOutput()))
        ) { error in
            XCTAssertEqual((error as? ProbeError)?.exitCode, 1)
            XCTAssertTrue("\(error)".contains("simprobe tree"), "\(error)")
        }
        XCTAssertEqual(client.operations, [.tree], "nothing may be tapped after a failed lookup")
    }

    /// The hint has to name the fix, because "no daemon" is not actionable on its own.
    func testAMissingDaemonExitsTwoWithTheStartCommand() {
        let client = FakeDaemonClient.absent(udid: "UDID")

        XCTAssertThrowsError(
            try TapRunner(options: TapOptions(udid: "UDID", target: .point(.init(x: 1, y: 2))))
                .run(through: client, in: Self.environment(RecordingOutput()))
        ) { error in
            XCTAssertEqual((error as? ProbeError)?.exitCode, 2)
            XCTAssertTrue("\(error)".contains("simprobe daemon start --udid"), "\(error)")
        }
    }

    /// A daemon that reports a failed tap must not be mistaken for one that tapped.
    func testAnInBandFailureBecomesAnExitCode() {
        let client = FakeDaemonClient(responses: [
            .tap: DaemonResponse(ok: false, kind: "idbFailed", message: "the companion died")
        ])

        XCTAssertThrowsError(
            try TapRunner(options: TapOptions(udid: "UDID", target: .point(.init(x: 1, y: 2))))
                .run(through: client, in: Self.environment(RecordingOutput()))
        ) { error in
            XCTAssertEqual((error as? ProbeError)?.exitCode, 2)
        }
    }

    func testJSONCarriesTheRefAndThePointItResolvedTo() throws {
        let output = try Self.tap("#tab.explore", json: true)

        XCTAssertEqual(
            output.recorded.out, ##"{"ms":1,"ref":"#tab.explore","x":81,"y":803}"##)
    }

    func testACoordinateTapReportsNoRef() throws {
        let output = try Self.tap("201,822", json: true)

        XCTAssertEqual(output.recorded.out, #"{"ms":1,"x":201,"y":822}"#)
    }

    // MARK: - Harness

    private struct TapOutput {
        let client: FakeDaemonClient
        let recorded: RecordingOutput
        let code: Int32
    }

    private static func tap(_ target: String, json: Bool = false) throws -> TapOutput {
        let client = FakeDaemonClient(responses: [
            .tree: DaemonResponse(ok: true, ms: 70, treeJSON: ElementFixture.describeAll),
            .tap: DaemonResponse(ok: true, ms: 1.0),
        ])
        let recorded = RecordingOutput()
        let options = TapOptions(
            udid: "UDID", target: try TapTarget.parse(target), json: json)
        let code = try TapRunner(options: options)
            .run(through: client, in: environment(recorded))
        return TapOutput(client: client, recorded: recorded, code: code)
    }

    /// A capture that is never reached: nothing here asks for `--wait-stable`, and a runner that
    /// captured anyway would be doing work the caller did not ask for.
    private static func environment(_ output: RecordingOutput) -> ProbeEnvironment {
        ProbeEnvironment(
            capture: ScriptedCapture(frames: []),
            clock: VirtualClock(),
            output: output
        )
    }
}
