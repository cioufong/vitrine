import XCTest
import Virtualization
@testable import VitrineVZ
@testable import VitrineCore

final class NestedVirtualizationTests: XCTestCase {
    func testOnlyVZLinuxGuestsMayEnableIt() throws {
        var c = VMConfig(name: "n", guestOS: .linux, cpuCount: 2, memoryMiB: 4096)
        c.disks = [.init(path: "disk.img")]
        c.features.nestedVirtualization = true
        XCTAssertNoThrow(try c.validate())
        c.backend = .qemu
        XCTAssertThrowsError(try c.validate())
        var mac = VMConfig(name: "m", guestOS: .macOS, cpuCount: 2, memoryMiB: 4096)
        mac.disks = [.init(path: "disk.img")]
        mac.features.nestedVirtualization = true
        XCTAssertThrowsError(try mac.validate())
    }

    func testOlderConfigsDecodeWithItOff() throws {
        let features = try JSONDecoder().decode(VMConfig.Features.self, from: Data(#"{"clipboard":true}"#.utf8))
        XCTAssertFalse(features.nestedVirtualization)
    }

    /// On a Mac without support the VM refuses to start with a clear message instead of booting
    /// without KVM; with support the platform has it switched on.
    func testPlatformFollowsHostSupport() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nested-\(UUID().uuidString).vitrinevm")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = VMBundle(url: dir)
        if ConfigurationBuilder.nestedVirtualizationSupported, #available(macOS 15, *) {
            XCTAssertTrue(try ConfigurationBuilder.linuxPlatform(bundle: bundle, nested: true).isNestedVirtualizationEnabled)
        } else {
            XCTAssertThrowsError(try ConfigurationBuilder.linuxPlatform(bundle: bundle, nested: true)) { error in
                XCTAssertTrue(error.localizedDescription.contains("M3"))
            }
        }
        XCTAssertNoThrow(try ConfigurationBuilder.linuxPlatform(bundle: bundle, nested: false))
    }
}
