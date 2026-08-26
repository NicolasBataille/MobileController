import Foundation
import XCTest

@testable import SimProbeCLI

/// `frames` is the verb that gives an agent coordinates: everything asserted here is about the
/// shape of what it prints, because that shape is what a caller parses.
final class FramesCommandTests: XCTestCase {

    // MARK: - Parsing

    func testParsesIdbJSONIntoElements() throws {
        let snapshot = try AccessibilityElementParser.parseAll(
            Data(ElementFixture.describeAll.utf8))

        XCTAssertEqual(snapshot.appLabel, ElementFixture.appLabel)
        XCTAssertEqual(snapshot.screen, ElementFrame(x: 0, y: 0, width: 402, height: 874))
        // The application element becomes the header and is not one of the listed elements.
        XCTAssertEqual(snapshot.elements.count, 11)
        XCTAssertEqual(snapshot.elements.first?.index, 1)
        XCTAssertEqual(snapshot.elements.first?.ref, "#nav.back")
        // Fractional idb coordinates are rounded to whole points, the unit `shot` writes in.
        let heading = try XCTUnwrap(snapshot.elements.first { $0.index == 2 })
        XCTAssertEqual(heading.ref, "@2")
        XCTAssertEqual(heading.frame, ElementFrame(x: 16, y: 120, width: 147, height: 41))
    }

    func testMapsIdbTypesOntoTheShortVocabulary() throws {
        let kinds = try Self.parsed().elements.reduce(into: [Int: ElementKind]()) {
            $0[$1.index] = $1.kind
        }

        XCTAssertEqual(kinds[1], .button)
        XCTAssertEqual(kinds[2], .text)  // Heading
        XCTAssertEqual(kinds[3], .text)  // StaticText
        XCTAssertEqual(kinds[4], .textField)
        XCTAssertEqual(kinds[5], .toggle)  // CheckBox is how idb reports a switch
        XCTAssertEqual(kinds[6], .image)
        XCTAssertEqual(kinds[7], .other)  // Group
        XCTAssertEqual(ElementKind(idbType: "SomethingAppleShipsIn2030"), .other)
    }

    func testLabelFallsBackToValueAndIsTruncatedByCharacter() throws {
        let elements = try Self.parsed().elements

        let field = try XCTUnwrap(elements.first { $0.ref == "#form.email" })
        XCTAssertEqual(field.label, "user@example.com")
        let heading = try XCTUnwrap(elements.first { $0.index == 2 })
        XCTAssertEqual(heading.label, "Bienvenue dans la démonstration d'acces…")
        XCTAssertEqual(heading.label.count, AccessibilityElement.labelLimit)
        // A CJK label is short in characters and long in bytes; the cap counts characters.
        let cjk = try XCTUnwrap(elements.first { $0.index == 3 })
        XCTAssertEqual(cjk.label, "こんばんは")
        // Nothing to say about a bare container, said as nothing rather than as a guess.
        XCTAssertEqual(elements.first { $0.index == 7 }?.label, "")
    }

    // MARK: - Rendering

    /// The golden form. Columns are sized from the content and padded by *character*, so the
    /// CJK row reads narrow in a terminal that draws it double-width — alignment is a reading
    /// aid, and the coordinates on every line are the answer.
    func testBandsElementsAndDropsWhatCannotBeTapped() throws {
        let output = RecordingOutput()

        let code = try FramesRunner(options: Self.options())
            .run(describing: StubElementDescriber(try Self.parsed()), to: output)

        XCTAssertEqual(code, 0)
        // The zero-size #hidden.probe and the fully offscreen #offscreen.next are both gone.
        XCTAssertEqual(
            output.out,
            """
            DemoApp  402x874
            [Top y<120]
              @7            Other      ""                                          (0,0 402x874)
              #nav.back     Button     "Back"                                      (16,62 44x44)
            [Content]
              @2            Text       "Bienvenue dans la démonstration d'acces…"  (16,120 147x41)
              @3            Text       "こんばんは"                                     (24,200 64x13)
              #form.email   TextField  "user@example.com"                          (36,260 330x44)
              #form.motion  Switch     "Réduire les animations"                    (36,320 330x28)
              @6            Image      "Logo"                                      (170,380 62x62)
              #form.submit  Button     "Envoyer"                                   (16,430 370x52)
            [Bottom y≥754]
              #tab.explore  Button     "Étude"                                     (22,781 119x44)
            """
        )
    }

    func testInteractiveKeepsOnlyWhatCanBeActedOn() throws {
        let output = RecordingOutput()

        _ = try FramesRunner(options: Self.options(interactiveOnly: true))
            .run(describing: StubElementDescriber(try Self.parsed()), to: output)

        // Text, Image and Other are gone, and so is the disabled #form.submit button.
        XCTAssertEqual(
            output.outLines.filter { $0.hasPrefix("  ") }.map { $0.split(separator: " ")[0] },
            ["#nav.back", "#form.email", "#form.motion", "#tab.explore"]
        )
        XCTAssertEqual(output.outLines.first, "DemoApp  402x874")
    }

    func testJSONEmitsOneObjectPerElementWithTheDocumentedKeys() throws {
        let output = RecordingOutput()

        _ = try FramesRunner(options: Self.options(json: true))
            .run(describing: StubElementDescriber(try Self.parsed()), to: output)

        XCTAssertEqual(output.outLines.count, 1)
        let rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.out.utf8)) as? [[String: Any]]
        )
        XCTAssertEqual(rows.count, 9)
        let first = try XCTUnwrap(rows.first)
        XCTAssertEqual(Set(first.keys), ["ref", "type", "label", "x", "y", "w", "h"])
        let tab = try XCTUnwrap(rows.first { $0["ref"] as? String == "#tab.explore" })
        XCTAssertEqual(tab["type"] as? String, "Button")
        XCTAssertEqual(tab["label"] as? String, "Étude")
        XCTAssertEqual(
            [tab["x"], tab["y"], tab["w"], tab["h"]].map { $0 as? Int }, [22, 781, 119, 44])
    }

    // MARK: - --point

    func testPointPrintsOnlyTheElementUnderIt() throws {
        let hit = try XCTUnwrap(
            AccessibilityElementParser.parseOne(Data(ElementFixture.describePoint.utf8)))
        let output = RecordingOutput()

        _ = try FramesRunner(options: Self.options(point: ElementPoint(x: 60, y: 800)))
            .run(describing: StubElementDescriber(try Self.parsed(), hit: hit), to: output)

        XCTAssertEqual(
            output.outLines, ["  #tab.explore  Button  \"Étude\"  (22,781 119x44)"])
    }

    func testPointWithNothingUnderItSaysSoAndStillExitsZero() throws {
        let output = RecordingOutput()

        let code = try FramesRunner(options: Self.options(point: ElementPoint(x: 1, y: 1)))
            .run(describing: StubElementDescriber(try Self.parsed()), to: output)

        XCTAssertEqual(code, 0)
        XCTAssertEqual(output.outLines, ["no element at (1,1)"])
    }

    func testPointRejectsMalformedCoordinates() {
        XCTAssertEqual(try? ElementPoint.parse("22,781"), ElementPoint(x: 22, y: 781))
        XCTAssertNil(ElementPoint(argument: "nope"))
        for bad in ["22", "22,", "a,b", "22,781,3", ""] {
            XCTAssertThrowsError(try ElementPoint.parse(bad), bad) { error in
                XCTAssertEqual((error as? ProbeError)?.exitCode, 1)
            }
        }
    }

    // MARK: - idb plumbing

    func testMissingIdbIsADependencyErrorWithAnInstallHint() {
        let runner = StubProcessRunner(result: .failed("idb not found", status: 1))

        XCTAssertThrowsError(try Idb.locate(runner: runner)) { error in
            let probeError = error as? ProbeError
            XCTAssertEqual(probeError?.exitCode, 2)
            XCTAssertEqual(probeError?.kind, "dependencyMissing")
            let message = probeError?.description ?? ""
            XCTAssertTrue(message.contains("brew install facebook/fb/idb-companion"), message)
            XCTAssertTrue(message.contains("pip3 install fb-idb"), message)
        }
    }

    func testFirstCallAfterBootIsRetriedOnceAfterConnect() throws {
        let runner = ScriptedProcessRunner(results: [
            .failed(ElementFixture.noTranslationObject),
            .ok("udid: … is_local: True"),
            .ok(ElementFixture.describeAll),
        ])

        let snapshot = try IdbElementDescriber(idb: "/usr/bin/true", runner: runner)
            .describeAll(udid: Fixtures.udid)

        XCTAssertEqual(snapshot.elements.count, 11)
        XCTAssertEqual(
            runner.verbs,
            [
                "ui describe-all --udid \(Fixtures.udid) --json",
                "connect \(Fixtures.udid)",
                "ui describe-all --udid \(Fixtures.udid) --json",
            ]
        )
    }

    func testAFailureThatSurvivesTheRetryIsAnEnvironmentError() {
        let runner = ScriptedProcessRunner(results: [
            .failed("boom"), .ok(""), .failed("still boom"),
        ])

        XCTAssertThrowsError(
            try IdbElementDescriber(idb: "/usr/bin/true", runner: runner)
                .describeAll(udid: Fixtures.udid)
        ) { error in
            XCTAssertEqual((error as? ProbeError)?.exitCode, 2)
            XCTAssertEqual((error as? ProbeError)?.kind, "idbFailed")
            XCTAssertTrue("\(error)".contains("still boom"), "\(error)")
        }
    }

    func testUnreadableIdbOutputIsReportedRatherThanGuessedAt() {
        XCTAssertThrowsError(try AccessibilityElementParser.parseAll(Data("not json".utf8))) {
            XCTAssertEqual(($0 as? ProbeError)?.exitCode, 2)
        }
    }

    // MARK: - Helpers

    private static func parsed() throws -> ElementSnapshot {
        try AccessibilityElementParser.parseAll(Data(ElementFixture.describeAll.utf8))
    }

    private static func options(
        interactiveOnly: Bool = false,
        point: ElementPoint? = nil,
        json: Bool = false
    ) -> FramesOptions {
        FramesOptions(
            udid: Fixtures.udid, interactiveOnly: interactiveOnly, point: point, json: json)
    }
}
