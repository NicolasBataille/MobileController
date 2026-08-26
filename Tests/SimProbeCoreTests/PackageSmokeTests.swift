import XCTest

@testable import SimProbeCore

final class PackageSmokeTests: XCTestCase {
    func testCoreModuleIsImportable() {
        XCTAssertEqual(SimProbeCore.version, "0.1.0")
    }
}
