import SimProbeCore
import XCTest

final class CLISmokeTests: XCTestCase {
    func testCoreVersionIsNotEmpty() {
        XCTAssertFalse(SimProbeCore.version.isEmpty)
    }
}
