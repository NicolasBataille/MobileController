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

    /// An app may reuse an identifier across a screen, and "the first match" is a coin flip the
    /// caller did not ask for. Both candidates are named by index, which is what tells them
    /// apart — the ref they share does not.
    func testADuplicateRefIsRefusedRatherThanResolvedToTheFirstMatch() {
        let snapshot = Self.snapshot(
            Self.element(
                index: 3, identifier: "row.item", frame: .init(x: 0, y: 10, width: 40, height: 40)),
            Self.element(
                index: 7, identifier: "row.item", frame: .init(x: 0, y: 90, width: 40, height: 40))
        )

        XCTAssertThrowsError(try TapTarget.identifier("row.item").resolve(in: snapshot)) { error in
            XCTAssertEqual((error as? ProbeError)?.exitCode, 1)
            XCTAssertTrue("\(error)".contains("@3"), "\(error)")
            XCTAssertTrue("\(error)".contains("@7"), "\(error)")
        }
    }

    /// idb reports hidden controls at `0x0`; their centre is the origin, and a tap there lands
    /// on whatever is drawn underneath.
    func testAnElementWithNoAreaIsNotSomethingToTap() throws {
        let snapshot = try DaemonElementDescriber(client: Self.treeClient())
            .describeAll(udid: "UDID")

        XCTAssertThrowsError(try TapTarget.identifier("hidden.probe").resolve(in: snapshot)) {
            XCTAssertEqual(($0 as? ProbeError)?.exitCode, 1)
            XCTAssertTrue("\($0)".contains("empty frame"), "\($0)")
        }
    }

    /// A row scrolled out of view keeps its real coordinates. Tapping them lands on whatever is
    /// drawn at the clamped edge instead — a different row, silently.
    func testAnElementOffTheScreenIsRefusedWithTheCoordinatesItWouldHaveTapped() throws {
        let snapshot = try DaemonElementDescriber(client: Self.treeClient())
            .describeAll(udid: "UDID")

        XCTAssertThrowsError(try TapTarget.identifier("offscreen.next").resolve(in: snapshot)) {
            XCTAssertEqual(($0 as? ProbeError)?.exitCode, 1)
            XCTAssertTrue("\($0)".contains("1226"), "\($0)")
            XCTAssertTrue("\($0)".contains("scroll it into view"), "\($0)")
        }
    }

    /// The whole point of the tap path is that a coordinate target costs no tree, so the guard
    /// on a bare `x,y` is the one that can be applied without one: off every screen there is.
    func testANegativeCoordinateIsRefusedAtParseTime() {
        for text in ["-1,10", "10,-1", "-1,-1"] {
            XCTAssertThrowsError(try TapTarget.parse(text), text) { error in
                XCTAssertEqual((error as? ProbeError)?.exitCode, 1, text)
                XCTAssertTrue("\(error)".contains("off screen"), "\(error)")
            }
        }
        XCTAssertEqual(try TapTarget.parse("0,0"), .point(ElementPoint(x: 0, y: 0)))
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

    private static func treeClient() -> FakeDaemonClient {
        FakeDaemonClient(responses: [
            .tree: DaemonResponse(ok: true, ms: 70, treeJSON: ElementFixture.describeAll)
        ])
    }

    /// The fixture's own screen, so an "off screen" assertion means the same thing here as it
    /// does everywhere else in this suite.
    private static func snapshot(_ elements: AccessibilityElement...) -> ElementSnapshot {
        ElementSnapshot(
            appLabel: ElementFixture.appLabel,
            screen: ElementFrame(x: 0, y: 0, width: 402, height: 874),
            elements: elements
        )
    }

    private static func element(index: Int, identifier: String, frame: ElementFrame)
        -> AccessibilityElement
    {
        AccessibilityElement(
            index: index,
            identifier: identifier,
            kind: .button,
            label: "Row",
            frame: frame,
            isEnabled: true
        )
    }

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
