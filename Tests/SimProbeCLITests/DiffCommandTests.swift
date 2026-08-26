import Foundation
import SimProbeCore
import XCTest

@testable import SimProbeCLI

final class DiffCommandTests: XCTestCase {

    func testIdenticalFilesExitZero() throws {
        let path = try writePNG(try TestFrames.thumbnail(base: 120))
        let output = RecordingOutput()

        let code = try DiffRunner(options: .init(lhs: path, rhs: path)).run(to: output)

        XCTAssertEqual(code, 0)
        XCTAssertEqual(output.out, "diff 0.00  (40x87 gray, tol 0.50)  ->  same")
    }

    func testDifferentFilesExitFour() throws {
        let before = try writePNG(try TestFrames.thumbnail(base: 0))
        let after = try writePNG(try TestFrames.thumbnail(base: 255))
        let output = RecordingOutput()

        let code = try DiffRunner(options: .init(lhs: before, rhs: after)).run(to: output)

        XCTAssertEqual(code, 4)
        XCTAssertEqual(output.out, "diff 255.00  (40x87 gray, tol 0.50)  ->  different")
    }

    func testUnreadableFileExitsFive() throws {
        let real = try writePNG(try TestFrames.thumbnail(base: 10))
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("simprobe-absent-\(UUID().uuidString).png")

        XCTAssertThrowsError(
            try DiffRunner(options: .init(lhs: real, rhs: missing)).run(to: RecordingOutput())
        ) {
            XCTAssertEqual(($0 as? ProbeError)?.exitCode, 5)
        }
    }

    func testJSONFormReportsTheSameVerdict() throws {
        let before = try writePNG(try TestFrames.thumbnail(base: 100))
        let after = try writePNG(try TestFrames.thumbnail(base: 100, raisedPixels: 3_480))
        let output = RecordingOutput()

        let code = try DiffRunner(options: .init(lhs: before, rhs: after, tolerance: 2, json: true))
            .run(to: output)

        XCTAssertEqual(code, 0)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.out.utf8)) as? [String: Any]
        )
        XCTAssertEqual(Set(payload.keys), ["diff", "tol", "same", "size"])
        XCTAssertEqual(payload["same"] as? Bool, true)
        XCTAssertEqual(payload["diff"] as? Double, 1)
    }

    private func writePNG(_ image: CGImage) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("simprobe-diff-\(UUID().uuidString).png")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try ImageEncoder.writePNG(image, to: url)
        return url
    }
}
