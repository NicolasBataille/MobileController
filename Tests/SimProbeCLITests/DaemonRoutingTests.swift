import Foundation
import XCTest

@testable import SimProbeCLI

/// What the daemon does with a request once it has been read off the socket.
///
/// The gRPC below is a fake and the socket above is absent, which leaves exactly the decisions
/// worth asserting: which operation calls what, what a failure turns into, and whether the
/// process is meant to keep serving afterwards.
final class DaemonRoutingTests: XCTestCase {

    func testPingReportsThePidAndUptimeWithoutTouchingTheCompanion() async throws {
        let actor = FakeIdbActor()

        let reply = await Self.router(actor, startedAtMicroseconds: 0).reply(to: .ping)

        XCTAssertTrue(reply.response.ok)
        XCTAssertEqual(reply.response.pid, 4_242)
        XCTAssertEqual(reply.response.udid, "UDID")
        XCTAssertNotNil(reply.response.uptimeMs)
        XCTAssertFalse(reply.shouldStop)
        let taps = await actor.taps
        XCTAssertTrue(taps.isEmpty)
    }

    func testTreeCarriesTheCompanionPayloadVerbatim() async throws {
        let actor = FakeIdbActor(treeJSON: ElementFixture.describeAll)

        let reply = await Self.router(actor).reply(to: .tree)

        XCTAssertTrue(reply.response.ok)
        XCTAssertEqual(reply.response.treeJSON, ElementFixture.describeAll)
        XCTAssertFalse(reply.shouldStop)
    }

    func testTapForwardsTheCoordinatesAndTimesTheCall() async throws {
        let actor = FakeIdbActor()

        let reply = await Self.router(actor).reply(to: .tap(x: 201, y: 822))

        XCTAssertTrue(reply.response.ok)
        let taps = await actor.taps
        XCTAssertEqual(taps, [FakeIdbActor.Tap(x: 201, y: 822)])
        // The fake ticker advances 1.1 ms per reading, which is what a real warm tap costs —
        // and a duration reported in whole milliseconds could not tell that from 2 ms.
        XCTAssertEqual(reply.response.ms, 1.1)
    }

    func testATapWithoutCoordinatesIsRejectedRatherThanGuessed() async {
        let reply = await Self.router(FakeIdbActor()).reply(to: DaemonRequest(op: .tap, x: 12))

        XCTAssertFalse(reply.response.ok)
        XCTAssertEqual(reply.response.kind, "invalidArgument")
        XCTAssertFalse(reply.shouldStop)
    }

    /// A failing call is reported in band and the daemon keeps serving: a companion that died
    /// mid-loop must not take the warm process with it.
    func testAFailedCallIsReportedWithoutStoppingTheDaemon() async {
        let actor = FakeIdbActor(failing: .idbFailed(command: "hid", detail: "no companion"))

        let reply = await Self.router(actor).reply(to: .tap(x: 1, y: 2))

        XCTAssertFalse(reply.response.ok)
        XCTAssertEqual(reply.response.kind, "idbFailed")
        XCTAssertEqual(reply.response.message, "idb hid failed: no companion")
        XCTAssertFalse(reply.shouldStop)
    }

    /// A NaN reaches the HID stream as a point the companion answers for seconds later, and a
    /// negative one lands off screen: both are the caller's arithmetic, not a tap.
    func testUnusableCoordinatesAreRefusedBeforeTheyReachTheCompanion() async {
        let actor = FakeIdbActor()

        for request in [
            DaemonRequest.tap(x: .nan, y: 10),
            .tap(x: 10, y: .infinity),
            .tap(x: -1, y: 10),
            .tap(x: 10, y: -0.5),
        ] {
            let reply = await Self.router(actor).reply(to: request)

            XCTAssertFalse(reply.response.ok, "\(request)")
            XCTAssertEqual(reply.response.kind, "invalidArgument", "\(request)")
        }
        let taps = await actor.taps
        XCTAssertTrue(taps.isEmpty, "nothing may reach the HID stream")
    }

    func testZeroIsATappablePoint() async {
        let actor = FakeIdbActor()

        let reply = await Self.router(actor).reply(to: .tap(x: 0, y: 0))

        XCTAssertTrue(reply.response.ok)
        let taps = await actor.taps
        XCTAssertEqual(taps, [FakeIdbActor.Tap(x: 0, y: 0)])
    }

    // MARK: - Before the companion answers

    /// The daemon binds its socket first and reaches the companion afterwards, so that `daemon
    /// start` can never lose track of a process it spawned. In that window `ping` has to answer
    /// — and has to say that this is what it is.
    func testAConnectingDaemonAnswersPingAndSaysSo() async {
        let reply = await Self.connectingRouter().reply(to: .ping)

        XCTAssertTrue(reply.response.ok)
        XCTAssertEqual(reply.response.connecting, true)
        XCTAssertEqual(reply.response.pid, 4_242)
        XCTAssertFalse(reply.shouldStop)
    }

    func testAConnectedDaemonDoesNotSayItIsConnecting() async {
        let reply = await Self.router(FakeIdbActor()).reply(to: .ping)

        XCTAssertNil(reply.response.connecting)
    }

    func testAConnectingDaemonRefusesWorkItCannotDoYet() async {
        for request in [DaemonRequest.tree, .tap(x: 1, y: 2)] {
            let reply = await Self.connectingRouter().reply(to: request)

            XCTAssertFalse(reply.response.ok, "\(request)")
            XCTAssertEqual(
                (try? DaemonProtocol.unwrap(reply.response, op: request.op)) == nil, true)
            XCTAssertTrue("\(reply.response.message ?? "")".contains("connecting"), "\(request)")
            XCTAssertFalse(reply.shouldStop)
        }
    }

    /// Otherwise a slow `idb connect` is an unkillable process.
    func testAConnectingDaemonCanStillBeStopped() async {
        let reply = await Self.connectingRouter().reply(to: .stop)

        XCTAssertTrue(reply.response.ok)
        XCTAssertTrue(reply.shouldStop)
    }

    func testStopIsTheOnlyOperationThatEndsTheLoop() async {
        let reply = await Self.router(FakeIdbActor()).reply(to: .stop)

        XCTAssertTrue(reply.response.ok)
        XCTAssertTrue(reply.shouldStop)
    }

    func testAFailingTreeReportsTheFailureAndNoPayload() async {
        let actor = FakeIdbActor(failing: .idbFailed(command: "accessibility_info", detail: "x"))

        let reply = await Self.router(actor).reply(to: .tree)

        XCTAssertFalse(reply.response.ok)
        XCTAssertNil(reply.response.treeJSON)
    }

    /// Sub-millisecond resolution is the point: rounding to whole milliseconds would report the
    /// daemon's headline number as either 1 or 2.
    func testDurationsKeepTwoDecimals() {
        XCTAssertEqual(DaemonRouter.milliseconds(since: 0, now: 1_100), 1.1)
        XCTAssertEqual(DaemonRouter.milliseconds(since: 0, now: 512), 0.51)
        XCTAssertEqual(DaemonRouter.milliseconds(since: 100, now: 0), 0)
    }

    private static func connectingRouter() -> DaemonRouter {
        DaemonRouter(
            actor: nil,
            udid: "UDID",
            pid: 4_242,
            ticker: FakeTicker(),
            startedAtMicroseconds: 0
        )
    }

    private static func router(_ actor: FakeIdbActor, startedAtMicroseconds: Int = 0)
        -> DaemonRouter
    {
        DaemonRouter(
            actor: actor,
            udid: "UDID",
            pid: 4_242,
            ticker: FakeTicker(),
            startedAtMicroseconds: startedAtMicroseconds
        )
    }
}
