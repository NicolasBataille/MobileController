import Foundation
import XCTest

@testable import SimProbeCLI

/// The wire between `simprobe` and `simprobe-daemon`.
///
/// Both sides are in this bundle, which is the point of putting the codec in the library rather
/// than in the daemon: the protocol is provable without a socket, a simulator, or gRPC.
final class DaemonProtocolTests: XCTestCase {

    func testEveryOperationRoundTrips() throws {
        for request in [DaemonRequest.ping, .tree, .stop, .tap(x: 201, y: 822)] {
            let line = try DaemonProtocol.encode(request)

            XCTAssertEqual(try DaemonProtocol.decodeRequest(line), request, line)
        }
    }

    func testARequestLineIsOneLineOfJSON() throws {
        let line = try DaemonProtocol.encode(.tap(x: 201, y: 822))

        XCTAssertFalse(line.contains("\n"), line)
        XCTAssertEqual(line, #"{"op":"tap","x":201,"y":822}"#)
    }

    /// The tree is carried as a *string*, so a payload full of quotes survives the round trip
    /// byte for byte and reaches the parser exactly as the companion emitted it.
    func testTreeJSONSurvivesEncodingVerbatim() throws {
        let payload = #"[{"AXLabel":"Réglages","frame":{"x":0,"y":0,"width":402,"height":874}}]"#
        let response = DaemonResponse(ok: true, ms: 70.2, treeJSON: payload)

        let decoded = try DaemonProtocol.decodeResponse(try DaemonProtocol.encode(response))

        XCTAssertEqual(decoded.treeJSON, payload)
        XCTAssertEqual(decoded, response)
    }

    func testAFailureCarriesTheErrorKindAndMessage() throws {
        let response = DaemonResponse.failure(.idbFailed(command: "hid", detail: "no companion"))

        let decoded = try DaemonProtocol.decodeResponse(try DaemonProtocol.encode(response))

        XCTAssertFalse(decoded.ok)
        XCTAssertEqual(decoded.kind, "idbFailed")
        XCTAssertEqual(decoded.message, "idb hid failed: no companion")
    }

    func testAnUnknownOperationIsRejected() {
        XCTAssertThrowsError(try DaemonProtocol.decodeRequest(#"{"op":"launch"}"#)) { error in
            XCTAssertEqual((error as? ProbeError)?.exitCode, 2)
        }
    }

    func testATruncatedLineIsRejected() {
        XCTAssertThrowsError(try DaemonProtocol.decodeRequest(#"{"op":"ta"#))
        XCTAssertThrowsError(try DaemonProtocol.decodeRequest("   \n"))
    }

    /// A trailing newline is the frame terminator, not part of the payload.
    func testATerminatedLineDecodes() throws {
        XCTAssertEqual(try DaemonProtocol.decodeRequest(#"{"op":"ping"}"# + "\n"), .ping)
    }

    func testUnwrapTurnsAnInBandFailureBackIntoAThrow() {
        let response = DaemonResponse(ok: false, kind: "idbFailed", message: "the companion died")

        XCTAssertThrowsError(try DaemonProtocol.unwrap(response, op: .tap)) { error in
            XCTAssertEqual(
                error as? ProbeError,
                .idbFailed(command: "daemon tap", detail: "the companion died")
            )
        }
    }

    func testUnwrapPassesASuccessThrough() throws {
        let response = DaemonResponse(ok: true, ms: 1.1)

        XCTAssertEqual(try DaemonProtocol.unwrap(response, op: .tap), response)
    }

    /// A daemon that says "no" without saying why still has to produce a usable message.
    func testAFailureWithNoMessageStillReads() {
        XCTAssertThrowsError(try DaemonProtocol.unwrap(DaemonResponse(ok: false), op: .tree)) {
            XCTAssertTrue("\($0)".contains("no message"), "\($0)")
        }
    }
}
