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
            #"{"fps":4.8,"samples":[{"diff":11,"tMs":0},{"diff":3.2,"tMs":210},"#
                + #"{"diff":0.4,"tMs":415},{"diff":0.01,"tMs":620}],"settledAtMs":415,"tol":0.5}"#
        )
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

    func testSettlePointIsTheFirstSampleWithinTolerance() {
        XCTAssertEqual(documented.settledAtMs, 415)
    }

    func testFPSIsMeasuredFromActualSampleTimestamps() {
        XCTAssertEqual(documented.fps, 4.8, accuracy: 0.05)
    }

    func testTimelineWithFewerThanTwoSamplesReportsZeroFPS() {
        let single = MotionTimeline(samples: [TimelineSample(tMs: 0, diff: 11.0)])

        XCTAssertEqual(single.fps, 0, accuracy: 1e-9)
        XCTAssertEqual(single.formatted(), "t=0 11.00  ->  not settled (1 samples, 0.0 fps)")
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
