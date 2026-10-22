import XCTest
@testable import VitrineCore

final class ConfigCompatibilityTests: XCTestCase {
    func testCurrentUSBDeviceMatchesBySerialThenPort() {
        let old = HostUSBDevice(vendorID: 1, productID: 2, locationID: 0x0110_0000, address: 3, registryID: 10, serial: "S1")
        let moved = HostUSBDevice(vendorID: 1, productID: 2, locationID: 0x0120_0000, address: 7, registryID: 11, serial: "S1")
        let other = HostUSBDevice(vendorID: 1, productID: 2, locationID: 0x0110_0000, address: 4, registryID: 12, serial: "S2")
        XCTAssertEqual(HostUSB.current(matching: old, in: [other, moved])?.address, 7)
        var noSerial = old; noSerial.serial = nil
        var replugged = old; replugged.serial = nil; replugged.address = 9
        XCTAssertEqual(HostUSB.current(matching: noSerial, in: [replugged])?.address, 9)
        XCTAssertNil(HostUSB.current(matching: old, in: [other]))
    }

    func testUDIFDetectionAndAgentToken() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appendingPathComponent("raw.img")
        try Data(count: 4096).write(to: raw)
        XCTAssertFalse(DiskImage.isUDIF(raw))
        var udif = Data(count: 4096 - 512)
        udif.append(Data("koly".utf8)); udif.append(Data(count: 508))
        let dmg = dir.appendingPathComponent("a.dmg")
        try udif.write(to: dmg)
        XCTAssertTrue(DiskImage.isUDIF(dmg))

        let bundle = VMBundle(url: dir.appendingPathComponent("t.vitrinevm"))
        try FileManager.default.createDirectory(at: bundle.url, withIntermediateDirectories: true)
        let t = try bundle.agentToken()
        XCTAssertEqual(t.count, 64)
        XCTAssertEqual(try bundle.agentToken(), t) // stable
        let mode = try FileManager.default.attributesOfItem(atPath: bundle.agentTokenURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testWindowsShareValidation() {
        var c = VMConfig(name: "w", guestOS: .windows, cpuCount: 2, memoryMiB: 4096)
        c.backend = .qemu
        c.disks = [.init(path: "disk.img")]
        c.shares = [.init(hostPath: "/tmp/100%done", name: "Data")]
        XCTAssertThrowsError(try c.validate(hostCPUs: 8, hostMemoryMiB: 16384))
        c.shares = [.init(hostPath: "/tmp", name: "vitrinetransfer")]
        XCTAssertThrowsError(try c.validate(hostCPUs: 8, hostMemoryMiB: 16384))
        c.shares = [.init(hostPath: "/tmp", name: "Data")]
        XCTAssertNoThrow(try c.validate(hostCPUs: 8, hostMemoryMiB: 16384))
    }

    func testFeatureDefaultsDecodeFromOldConfigs() throws {
        let f = try JSONDecoder().decode(VMConfig.Features.self, from: Data("{}".utf8))
        XCTAssertTrue(f.timeSync)
        XCTAssertEqual(f.usbConnect, .ask)
        let bad = try JSONDecoder().decode(VMConfig.Features.self, from: Data(#"{"usbConnect":"bogus"}"#.utf8))
        XCTAssertEqual(bad.usbConnect, .ask)
    }

    func testSnapshotsKeepUSBStateWithSavedMemory() {
        XCTAssertTrue(SnapshotStore.memoryFiles.contains("state.usb"))
        XCTAssertTrue(SnapshotStore.memoryFiles.contains("usb-attachments.json"))
    }
}
