import Foundation
import SimProbeCore
import XCTest

final class MotionTimelineTests: XCTestCase {

    /// The sample set from `docs/plans/02-architecture.md` section 4.
    private let documented = MotionTimeline(
        samples: [
            TimelineSample(tMs: 0, diff: 11.0),
            TimelineSample(tMs: 210, diff: 3.2),
            TimelineSample(tMs: 415, diff: 0.4),
            TimelineSample(tMs: 620, diff: 0.01),
        ],
        tolerance: 0.5
    )

    /// The live timeline that exposed the old "first quiet sample wins" rule: quiet at 286 ms,
    /// a transition across 605-838 ms, then still again.
    private let liveTransition = MotionTimeline(
        samples: [
            TimelineSample(tMs: 286, diff: 0.0),
            TimelineSample(tMs: 605, diff: 55.66),
            TimelineSample(tMs: 838, diff: 48.27),
            TimelineSample(tMs: 1_073, diff: 0.01),
            TimelineSample(tMs: 1_315, diff: 0.0),
        ],
        tolerance: 0.5
    )

    func testFormatsCompactTimelineWithSettlePoint() {
        XCTAssertEqual(
            documented.formatted(),
            "t=0 11.00, 210 3.20, 415 0.40, 620 0.01  ->  settled@415ms (4 samples, 4.8 fps)"
        )
    }

    func testJSONEncodingMatchesDocumentedShape() throws {
        let json = try String(decoding: documented.jsonEncoded(), as: UTF8.self)

        XCTAssertEqual(
            json,
            #"{"fps":4.8,"framesCapped":false,"hadMotion":true,"samples":[{"diff":11,"tMs":0},"#
                + #"{"diff":3.2,"tMs":210},{"diff":0.4,"tMs":415},{"diff":0.01,"tMs":620}],"#
                + #""settledAtMs":415,"tol":0.5}"#
        )
    }

    /// The cap shows in both output forms, so a short frame directory is never read as a
    /// short run.
    func testCappedFrameWritingIsReportedInBothForms() throws {
        let capped = MotionTimeline(
            samples: [TimelineSample(tMs: 0, diff: 11.0), TimelineSample(tMs: 200, diff: 0.0)],
            tolerance: 0.5,
            framesCappedAt: 10_000
        )

        XCTAssertTrue(capped.formatted().hasSuffix("(frames capped at 10000)"), capped.formatted())
        let json = try String(decoding: capped.jsonEncoded(), as: UTF8.self)
        XCTAssertTrue(json.contains(#""framesCapped":true"#), json)
    }

    func testTimelineWithNoSettlePointReportsNotSettled() throws {
        let moving = MotionTimeline(
            samples: [
                TimelineSample(tMs: 0, diff: 11.0),
                TimelineSample(tMs: 200, diff: 8.4),
                TimelineSample(tMs: 400, diff: 6.1),
            ],
            tolerance: 0.5
        )

        XCTAssertNil(moving.settledAtMs)
        XCTAssertEqual(
            moving.formatted(),
            "t=0 11.00, 200 8.40, 400 6.10  ->  not settled (3 samples, 5.0 fps)"
        )
        let json = try String(decoding: moving.jsonEncoded(), as: UTF8.self)
        XCTAssertTrue(json.contains(#""settledAtMs":null"#), json)
    }

    func testSettlePointIsFirstQuietSampleAfterLastMotion() {
        XCTAssertEqual(documented.settledAtMs, 415)
        XCTAssertTrue(liveTransition.hadMotion)
        // Not 286: that sample precedes the transition, it does not follow it.
        XCTAssertEqual(liveTransition.settledAtMs, 1_073)
        XCTAssertEqual(
            liveTransition.formatted(),
            "t=286 0.00, 605 55.66, 838 48.27, 1073 0.01, 1315 0.00  ->  "
                + "settled@1073ms (5 samples, 3.9 fps)"
        )
    }

    func testTimelineEndingInMotionReportsNotSettled() {
        let stillMoving = MotionTimeline(
            samples: Array(liveTransition.samples.prefix(3)),
            tolerance: liveTransition.tolerance
        )

        XCTAssertNil(stillMoving.settledAtMs)
        XCTAssertTrue(stillMoving.hadMotion)
        XCTAssertEqual(
            stillMoving.formatted(),
            "t=286 0.00, 605 55.66, 838 48.27  ->  not settled (3 samples, 3.6 fps)"
        )
    }

    func testAllQuietTimelineReportsNoMotion() throws {
        let quiet = MotionTimeline(
            samples: [
                TimelineSample(tMs: 0, diff: 0.0),
                TimelineSample(tMs: 200, diff: 0.01),
                TimelineSample(tMs: 400, diff: 0.0),
            ],
            tolerance: 0.5
        )

        XCTAssertFalse(quiet.hadMotion)
        XCTAssertEqual(quiet.settledAtMs, 0)
        XCTAssertEqual(
            quiet.formatted(),
            "t=0 0.00, 200 0.01, 400 0.00  ->  settled@0ms (3 samples, 5.0 fps) (no motion)"
        )
        let json = try String(decoding: quiet.jsonEncoded(), as: UTF8.self)
        XCTAssertTrue(json.contains(#""hadMotion":false"#), json)
    }

    func testFPSIsMeasuredFromActualSampleTimestamps() {
        XCTAssertEqual(documented.fps, 4.8, accuracy: 0.05)
    }

    func testTimelineWithFewerThanTwoSamplesReportsZeroFPS() {
        let single = MotionTimeline(samples: [TimelineSample(tMs: 0, diff: 11.0)])

        XCTAssertEqual(single.fps, 0, accuracy: 1e-9)
        XCTAssertEqual(single.formatted(), "t=0 11.00  ->  not settled (1 sample, 0.0 fps)")
    }

    func testEmptyTimelineFormatsExplicitly() {
        let empty = MotionTimeline(samples: [])

        XCTAssertNil(empty.settledAtMs)
        XCTAssertEqual(empty.formatted(), "no samples")
    }

    func testFormattedOutputCarriesNoImageBytes() {
        let line = documented.formatted()

        XCTAssertTrue(line.allSatisfy(\.isASCII))
        XCTAssertLessThan(line.utf8.count, 500)
    }
}
