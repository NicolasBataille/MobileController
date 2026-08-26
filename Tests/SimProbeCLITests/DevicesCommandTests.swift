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

    /// Runtimes are ordered by version number, not by the label's characters.
    ///
    /// `"iOS 9.0" > "iOS 26.5"` lexicographically, so a string comparison puts a decade-old
    /// runtime above the current one and the "newest first" contract silently inverts.
    func testRuntimeOrderingIsNumericNotLexicographic() throws {
        let mixed = [
            SimulatorDevice(
                udid: Fixtures.udid, name: "iPhone 5", runtime: "iOS 9.0", isBooted: false,
                isAvailable: true),
            SimulatorDevice(
                udid: Fixtures.otherUdid, name: "iPhone 17", runtime: "iOS 26.5", isBooted: false,
                isAvailable: true),
        ]
        let output = RecordingOutput()

        _ = try DevicesRunner(options: .init()).run(listing: StubDeviceLister(mixed), to: output)

        XCTAssertTrue(output.outLines.first?.contains("iOS 26.5") == true, output.out)
        XCTAssertTrue(output.outLines.dropFirst().first?.contains("iOS 9.0") == true, output.out)
        // And the same comparator orders what `simctl` handed back, before any filtering.
        let parsed = try SimctlDeviceLister.parse(Data(DeviceListFixture.mixedPlatforms.utf8))
        XCTAssertEqual(
            parsed.map(\.runtime), ["iOS 26.5", "watchOS 11.0", "iOS 9.0", "xrOS 2.0"])
    }

    func testPlatformFilterKeepsOnlyIOSRuntimes() throws {
        let output = RecordingOutput()
        let devices = try SimctlDeviceLister.parse(Data(DeviceListFixture.mixedPlatforms.utf8))

        _ = try DevicesRunner(options: .init(platform: .ios))
            .run(listing: StubDeviceLister(devices), to: output)

        XCTAssertTrue(
            output.outLines.dropLast().allSatisfy { $0.contains("iOS ") }, output.out)
        XCTAssertEqual(output.outLines.last, "2 devices, 0 booted")
    }

    func testPlatformFilterDefaultIsAll() throws {
        let output = RecordingOutput()
        let devices = try SimctlDeviceLister.parse(Data(DeviceListFixture.mixedPlatforms.utf8))

        XCTAssertEqual(DevicesOptions().platform, .all)
        XCTAssertEqual(try DevicesCommand.parse([]).platform, .all)
        _ = try DevicesRunner(options: .init()).run(listing: StubDeviceLister(devices), to: output)

        XCTAssertEqual(output.outLines.last, "4 devices, 0 booted")
        // watchOS and visionOS (whose runtime identifier reads `xrOS`) both survive.
        XCTAssertTrue(output.out.contains("watchOS 11.0"), output.out)
        XCTAssertTrue(output.out.contains("xrOS 2.0"), output.out)
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

    /// One simulator per platform, plus a decade-old iOS runtime: the ordering and the
    /// `--platform` filter are both only interesting when the list is mixed.
    static let mixedPlatforms = """
        {
          "devices" : {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5" : [
              { "udid" : "SIM-UDID-PLACEHOLDER-A", "isAvailable" : true,
                "name" : "iPhone 17", "state" : "Shutdown" }
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-9-0" : [
              { "udid" : "SIM-UDID-PLACEHOLDER-B", "isAvailable" : true,
                "name" : "iPhone 5", "state" : "Shutdown" }
            ],
            "com.apple.CoreSimulator.SimRuntime.watchOS-11-0" : [
              { "udid" : "SIM-UDID-PLACEHOLDER-C", "isAvailable" : true,
                "name" : "Apple Watch Series 10", "state" : "Shutdown" }
            ],
            "com.apple.CoreSimulator.SimRuntime.xrOS-2-0" : [
              { "udid" : "SIM-UDID-PLACEHOLDER-D", "isAvailable" : true,
                "name" : "Apple Vision Pro", "state" : "Shutdown" }
            ]
          }
        }
        """

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
