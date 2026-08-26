import ArgumentParser
import Foundation
import XCTest

@testable import SimProbeCLI

/// The CLI's contract with the shell: which failure produces which exit status, and on which
/// stream its explanation lands.
final class ErrorSurfaceTests: XCTestCase {

    /// One sample per `ProbeError` case. The compiler already forces every case through the
    /// `exitCode` and `kind` switches; this table is what makes a *wrong* mapping fail.
    private static let table: [(error: ProbeError, code: Int32)] = [
        (.invalidArgument("bad duration"), 1),
        (.simctlUnavailable("xcrun not found"), 2),
        (.simctlFailed(command: "list devices", detail: "boom"), 2),
        (.noBootedDevice, 2),
        (.ambiguousDevice(requested: nil, candidates: []), 2),
        (.deviceNotFound("iPhone 99"), 2),
        (.captureFailed("screenshot refused"), 5),
        (.frameFailure("size mismatch"), 5),
        (.imageUnreadable("/nowhere/x.png"), 5),
    ]

    func testEveryProbeErrorMapsToDocumentedExitCode() {
        for (error, expected) in Self.table {
            XCTAssertEqual(error.exitCode, expected, error.kind)
            XCTAssertFalse(error.description.isEmpty, error.kind)
        }
        // 3 and 4 are results, not errors, so no ProbeError may claim them.
        XCTAssertTrue(Self.table.allSatisfy { [1, 2, 5].contains($0.code) })
        XCTAssertEqual(Set(Self.table.map(\.error.kind)).count, Self.table.count)
    }

    func testJSONModeEmitsErrorObjectOnStdout() throws {
        let output = RecordingOutput()

        ErrorReporter.report(.noBootedDevice, json: true, to: output)

        XCTAssertEqual(output.errorLines, [])
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.out.utf8)) as? [String: Any]
        )
        let body = try XCTUnwrap(payload["error"] as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["error"])
        XCTAssertEqual(Set(body.keys), ["code", "kind", "message"])
        XCTAssertEqual(body["code"] as? Int, 2)
        XCTAssertEqual(body["kind"] as? String, "noBootedDevice")
        XCTAssertEqual(body["message"] as? String, ProbeError.noBootedDevice.description)
    }

    func testHumanModeEmitsMessageOnStderrAndNothingOnStdout() {
        let output = RecordingOutput()

        ErrorReporter.report(.deviceNotFound("iPhone 99"), json: false, to: output)

        XCTAssertEqual(output.outLines, [])
        XCTAssertEqual(
            output.errorLines,
            ["simprobe: no simulator named or identified by 'iPhone 99'"]
        )
    }

    func testCanonicalUDIDIsUsedWithoutListingDevices() throws {
        // Assembled rather than written out: a UDID-shaped literal has no place in a tracked
        // file, and the shape check is exactly what is under test.
        let canonical = [
            String(repeating: "a", count: 8), String(repeating: "1", count: 4),
            String(repeating: "b", count: 4), String(repeating: "2", count: 4),
            String(repeating: "c", count: 12),
        ].joined(separator: "-")
        let listing = StubDeviceLister(failing: .noBootedDevice)
        let session = ProbeSession(simctl: "/usr/bin/true", listing: listing)

        XCTAssertEqual(try session.udid(for: canonical), canonical)
    }

    func testNameIsResolvedThroughTheDeviceList() throws {
        let listing = StubDeviceLister([
            SimulatorDevice(
                udid: Fixtures.udid,
                name: "iPhone 17",
                runtime: "iOS 26.5",
                isBooted: true,
                isAvailable: true
            )
        ])
        let session = ProbeSession(simctl: "/usr/bin/true", listing: listing)

        XCTAssertEqual(try session.udid(for: "iPhone 17"), Fixtures.udid)
        XCTAssertEqual(try session.udid(for: nil), Fixtures.udid)
    }

    func testUsageErrorsExitOneRatherThanSixtyFour() {
        // ArgumentParser's own convention is 64; the architecture's table says 1.
        XCTAssertEqual(exitStatus(forParsing: ["wait-stable", "--no-such-flag"]), 1)
        XCTAssertEqual(exitStatus(forParsing: ["no-such-verb"]), 1)
    }

    func testVersionIsReportedAsACleanExit() {
        XCTAssertEqual(exitStatus(forParsing: ["--version"]), 0)
    }

    private func exitStatus(forParsing arguments: [String]) -> Int32 {
        do {
            _ = try SimProbe.parseAsRoot(arguments)
            return 0
        } catch {
            return SimProbeMain.processStatus(for: error)
        }
    }
}
