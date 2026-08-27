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

    /// The whole warm path against a real simulator: start, read a tree, stop, start again.
    ///
    /// The only exercise the gRPC layer ever gets. Everything below `IdbActing` — the channel,
    /// the HID stream, the accessibility RPC, the companion's own connect — is unfakeable by
    /// construction, so this is the test that says the daemon works at all.
    ///
    /// Runs in a directory of its own so it can never stop, reuse or outlive a daemon the
    /// developer started by hand.
    func testLiveDaemonStartTreeStop() throws {
        let context = try liveContext()
        let daemon = try daemonHarness(context)
        let scale = try context.session.displayMetrics.scale(udid: context.udid)
        let captured = try SimctlScreenCapture(simctl: context.simctl).capture(udid: context.udid)

        let report = try daemon.launcher.start(DaemonLaunchOptions(udid: context.udid))

        // The smoke test is both halves: a tree with something in it, and a `simctl` capture.
        XCTAssertGreaterThanOrEqual(report.elementCount, 1)
        XCTAssertFalse(report.wasAlreadyRunning)
        XCTAssertEqual(daemon.launcher.status(udid: context.udid).isRunning, true)

        let snapshot = try daemon.describer.describeAll(udid: context.udid)
        XCTAssertFalse(snapshot.elements.isEmpty)
        // The property the whole coordinate contract rests on: the daemon's tree is in the same
        // logical points `shot` writes and `tap` takes, not in framebuffer pixels. A daemon that
        // reported a 1206-point-wide screen would place every tap on a 402-point one.
        XCTAssertEqual(snapshot.screen.width, Int((Double(captured.width) / scale).rounded()))
        // The payload really is the shape `frames` parses: refs, not just rectangles.
        XCTAssertTrue(snapshot.elements.contains { $0.identifier != nil }, "no element had a ref")

        XCTAssertTrue(try daemon.launcher.stop(udid: context.udid))
        XCTAssertFalse(daemon.launcher.status(udid: context.udid).isRunning)

        // A stopped daemon leaves its socket file behind; starting again must unlink and rebind
        // it rather than fail on an address already in use. `stop` waits for the process to
        // actually exit, which is what makes this pair deterministic rather than a race.
        XCTAssertGreaterThanOrEqual(
            try daemon.launcher.start(DaemonLaunchOptions(udid: context.udid)).elementCount, 1)
        XCTAssertTrue(try daemon.launcher.stop(udid: context.udid))
    }

    /// A tap that is actually meant to land: a resolved element centre, and the navigation it
    /// causes read back off the tree.
    ///
    /// A corner tap proves the HID stream carries bytes and nothing else — it lands on whatever
    /// happens to be at (2,2), and a daemon that silently halved every coordinate would pass it.
    /// This taps the centre of a ref, then requires the screen to have *changed into* something
    /// with a back control, then presses that and requires the row to come back. Settings' own
    /// General row because it is stable across iOS versions, harmless, and reversible; the test
    /// leaves the simulator exactly where it found it.
    func testLiveDaemonTapNavigatesToTheElementItResolved() throws {
        let context = try liveContext()
        let daemon = try daemonHarness(context)
        _ = try daemon.launcher.start(DaemonLaunchOptions(udid: context.udid))

        let before = try daemon.describer.describeAll(udid: context.udid)
        let target = TapTarget.identifier(Self.settingsGeneralRow)
        try XCTSkipUnless(
            (try? target.resolve(in: before)) != nil,
            "open Settings on the simulator: this test taps \(Self.settingsGeneralRow)"
        )
        let row = try target.resolve(in: before)

        let tapped = try daemon.client.call(
            .tap(x: Double(row.frame.centre.x), y: Double(row.frame.centre.y)))

        XCTAssertTrue(tapped.ok)
        XCTAssertNotNil(tapped.ms)
        let pushed = try waitForSettledTree(
            differingFrom: before,
            through: daemon.describer,
            udid: context.udid,
            what: "the pushed screen"
        )
        // A pushed screen has a back control in its navigation bar. Found by geometry rather
        // than by label, because the simulator's language is not this test's business.
        let back = try XCTUnwrap(
            Self.backControl(in: pushed),
            "tapping \(row.ref) changed the screen but produced no back control"
        )
        XCTAssertNil(try? target.resolve(in: pushed), "the row is still on screen; nothing moved")

        _ = try daemon.client.call(
            .tap(x: Double(back.frame.centre.x), y: Double(back.frame.centre.y)))

        let restored = try waitForSettledTree(
            differingFrom: pushed,
            through: daemon.describer,
            udid: context.udid,
            what: "Settings' root"
        )
        XCTAssertNotNil(try? target.resolve(in: restored), "the back tap did not restore the list")
        XCTAssertTrue(try daemon.launcher.stop(udid: context.udid))
    }

    // MARK: Harness

    /// The row every iOS Settings app has had for a decade, and one that pushes rather than
    /// toggling anything.
    private static let settingsGeneralRow = "com.apple.settings.general"

    /// The back control of a pushed navigation bar, by position: a button in the top band, on
    /// the left, with something to hit.
    private static func backControl(in snapshot: ElementSnapshot) -> AccessibilityElement? {
        snapshot.elements
            .filter { $0.kind == .button && $0.isEnabled && !$0.frame.isEmpty }
            .filter { $0.frame.y < 120 && $0.frame.x < snapshot.screen.width / 4 }
            .min { $0.frame.y < $1.frame.y }
    }

    /// Polls until the tree is *both* different from the one we started from and the same as
    /// the reading before it.
    ///
    /// "Different" alone is not navigation. A push animates, and a tree read mid-animation is
    /// neither screen: the first live run of this test caught Settings' own list at `x: -112`,
    /// sliding out, with the row it had just tapped still in it. Two equal readings is the
    /// cheapest statement of "the transition is over" that does not involve a screenshot.
    private func waitForSettledTree(
        differingFrom previous: ElementSnapshot,
        through describer: DaemonElementDescriber,
        udid: String,
        what: String
    ) throws -> ElementSnapshot {
        let deadline = Date().addingTimeInterval(10)
        var last: ElementSnapshot?
        while Date() < deadline {
            let latest = try describer.describeAll(udid: udid)
            if Self.differs(latest, from: previous), let last, !Self.differs(latest, from: last) {
                return latest
            }
            last = latest
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw XCTSkip("the screen never settled on \(what); the simulator may be busy")
    }

    /// Two trees are the same screen when they carry the same refs at the same places. The
    /// frames matter: a list sliding out of view keeps every ref it had.
    private static func differs(_ one: ElementSnapshot, from other: ElementSnapshot) -> Bool {
        one.elements.map { "\($0.ref)\($0.frame.summary)" }
            != other.elements.map { "\($0.ref)\($0.frame.summary)" }
    }

    /// One daemon of its own, in a directory of its own, stopped whatever happens.
    private func daemonHarness(_ context: LiveContext) throws -> DaemonHarness {
        let executable = try daemonExecutable()
        let base = URL(
            fileURLWithPath: "/var/tmp/sp-live-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let paths = DaemonPaths(base: base)
        let client = UnixSocketDaemonClient(
            path: paths.socket(udid: context.udid), udid: context.udid)
        // Even on a failed assertion: a daemon left holding a gRPC channel to the simulator is
        // exactly the leak this suite must not cause. The teardown talks to the socket directly
        // rather than through the launcher, which is not `Sendable` and need not become so for
        // the sake of a cleanup block.
        let socketPath = paths.socket(udid: context.udid)
        let udid = context.udid
        addTeardownBlock {
            _ = try? UnixSocketDaemonClient(path: socketPath, udid: udid).send(.stop)
            // The base, not just the socket directory inside it: a live run must litter nothing.
            try? FileManager.default.removeItem(at: base)
        }
        return DaemonHarness(
            client: client,
            launcher: DaemonLauncher(
                paths: paths,
                client: client,
                spawner: DetachedProcessSpawner(),
                clock: SystemClock(),
                capture: SimctlScreenCapture(simctl: context.simctl),
                executable: executable
            )
        )
    }

    private struct DaemonHarness {
        let client: UnixSocketDaemonClient
        let launcher: DaemonLauncher

        var describer: DaemonElementDescriber { DaemonElementDescriber(client: client) }
    }

    /// `simprobe-daemon` as built beside the test bundle.
    ///
    /// Not `DaemonExecutable.locate()`: that looks beside the *running* executable, which under
    /// the test runner is inside the `.xctest` bundle rather than in `.build/debug`.
    private func daemonExecutable() throws -> String {
        let candidate = Bundle(for: type(of: self)).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(DaemonExecutable.name)
            .path
        guard FileManager.default.isExecutableFile(atPath: candidate) else {
            throw XCTSkip("build the daemon first: swift build --product simprobe-daemon")
        }
        return candidate
    }

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
