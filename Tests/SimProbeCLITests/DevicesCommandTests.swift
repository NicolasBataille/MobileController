import Foundation
import XCTest

@testable import SimProbeCLI

final class DevicesCommandTests: XCTestCase {

    func testParsesSimctlListJSONIntoDevices() throws {
        let runner = StubProcessRunner(standardOutput: DeviceListFixture.threeDevices)
        let lister = SimctlDeviceLister(simctl: "/usr/bin/true", runner: runner)

        let devices = try lister.devices()

        XCTAssertEqual(runner.invocations.first?.arguments, ["list", "devices", "--json"])
        XCTAssertEqual(devices.count, 3)
        XCTAssertEqual(
            devices.map(\.name),
            ["iPhone 17", "iPhone 17 Pro", "iPad Pro 13-inch"]
        )
        XCTAssertEqual(devices.map(\.runtime), ["iOS 26.5", "iOS 26.5", "iOS 26.4"])
        XCTAssertEqual(devices.map(\.udid).first, Fixtures.udid)
        XCTAssertEqual(devices.map(\.isAvailable), [true, true, false])
    }

    func testMarksBootedDevices() throws {
        let output = RecordingOutput()

        let code = try DevicesRunner(options: .init())
            .run(listing: StubDeviceLister(Self.devices), to: output)

        XCTAssertEqual(code, 0)
        XCTAssertEqual(
            output.outLines,
            [
                "BOOTED  iPad Pro 13-inch   iOS 26.4   SIM-UDID-PLACEHOLDER-C",
                "        iPhone 17          iOS 26.5   SIM-UDID-PLACEHOLDER-A",
                "        iPhone 17 Pro      iOS 26.5   SIM-UDID-PLACEHOLDER-B",
                "3 devices, 1 booted",
            ]
        )
    }

    func testResolvesUniqueNameToUDID() throws {
        let resolved = try DeviceResolver.resolve("iPhone 17 Pro", among: Self.devices)

        XCTAssertEqual(resolved.udid, Fixtures.otherUdid)
        XCTAssertEqual(
            try DeviceResolver.resolve(Fixtures.udid, among: Self.devices).name, "iPhone 17")
        // No argument at all falls back to the single booted device.
        XCTAssertEqual(
            try DeviceResolver.resolve(nil, among: Self.devices).name, "iPad Pro 13-inch")
    }

    func testAmbiguousNameExitsTwoWithBothCandidates() {
        let duplicates = [
            SimulatorDevice(
                udid: Fixtures.udid, name: "iPhone 17", runtime: "iOS 26.5", isBooted: true,
                isAvailable: true),
            SimulatorDevice(
                udid: Fixtures.otherUdid, name: "iPhone 17", runtime: "iOS 26.4", isBooted: true,
                isAvailable: true),
        ]

        XCTAssertThrowsError(try DeviceResolver.resolve("iPhone 17", among: duplicates)) { error in
            let probeError = error as? ProbeError
            XCTAssertEqual(probeError?.exitCode, 2)
            let message = "\(error)"
            XCTAssertTrue(message.contains(Fixtures.udid), message)
            XCTAssertTrue(message.contains(Fixtures.otherUdid), message)
        }
        // The same applies when nothing was requested and more than one device is booted.
        XCTAssertThrowsError(try DeviceResolver.resolve(nil, among: duplicates)) { error in
            XCTAssertEqual((error as? ProbeError)?.exitCode, 2)
        }
    }

    func testNoBootedDeviceExitsTwo() {
        let idle = Self.devices.map {
            SimulatorDevice(
                udid: $0.udid, name: $0.name, runtime: $0.runtime, isBooted: false,
                isAvailable: true)
        }

        XCTAssertThrowsError(try DeviceResolver.resolve(nil, among: idle)) { error in
            XCTAssertEqual((error as? ProbeError)?.exitCode, 2)
        }
        XCTAssertThrowsError(try DeviceResolver.resolve("iPhone 99", among: idle)) { error in
            XCTAssertEqual((error as? ProbeError)?.exitCode, 2)
        }
    }

    func testBootedFlagListsOnlyBootedDevices() throws {
        let output = RecordingOutput()

        _ = try DevicesRunner(options: .init(bootedOnly: true))
            .run(listing: StubDeviceLister(Self.devices), to: output)

        XCTAssertEqual(output.outLines.count, 2)
        XCTAssertEqual(output.outLines.last, "1 device, 1 booted")
    }

    private static let devices = [
        SimulatorDevice(
            udid: Fixtures.udid, name: "iPhone 17", runtime: "iOS 26.5", isBooted: false,
            isAvailable: true),
        SimulatorDevice(
            udid: Fixtures.otherUdid, name: "iPhone 17 Pro", runtime: "iOS 26.5", isBooted: false,
            isAvailable: true),
        SimulatorDevice(
            udid: "SIM-UDID-PLACEHOLDER-C", name: "iPad Pro 13-inch", runtime: "iOS 26.4",
            isBooted: true, isAvailable: true),
    ]
}

/// A trimmed, anonymised `simctl list devices --json`. The real output embeds an absolute
/// `dataPath` and `logPath` under the user's home directory; both are dropped, along with the
/// real UDIDs, so the fixture is safe in a public repository.
enum DeviceListFixture {
    static let threeDevices = """
        {
          "devices" : {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5" : [
              {
                "udid" : "SIM-UDID-PLACEHOLDER-A",
                "isAvailable" : true,
                "name" : "iPhone 17",
                "state" : "Booted"
              },
              {
                "udid" : "SIM-UDID-PLACEHOLDER-B",
                "isAvailable" : true,
                "name" : "iPhone 17 Pro",
                "state" : "Shutdown"
              }
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-4" : [
              {
                "udid" : "SIM-UDID-PLACEHOLDER-C",
                "isAvailable" : false,
                "name" : "iPad Pro 13-inch",
                "state" : "Shutdown"
              }
            ]
          }
        }
        """
}
