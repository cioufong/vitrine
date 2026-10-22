import Foundation
import XCTest
@testable import VitrineVZ
@testable import VitrineCore

/// Builds UTM bundles (configuration version 4) on disk and imports them into a throwaway library.
final class UTMImportTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private var savedHome: String?

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("vitrine-utm-\(UUID())")
        try fm.createDirectory(at: root.appendingPathComponent("library"), withIntermediateDirectories: true)
        savedHome = ProcessInfo.processInfo.environment["VITRINE_HOME"]
        setenv("VITRINE_HOME", root.appendingPathComponent("library").path, 1)
    }

    override func tearDownWithError() throws {
        if let savedHome { setenv("VITRINE_HOME", savedHome, 1) } else { unsetenv("VITRINE_HOME") }
        try? fm.removeItem(at: root)
    }

    private func makeUTM(_ name: String, _ plist: [String: Any], data: [String: Data]) throws -> URL {
        let utm = root.appendingPathComponent("\(name).utm")
        try fm.createDirectory(at: utm.appendingPathComponent("Data"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: utm.appendingPathComponent("config.plist"))
        for (file, bytes) in data { try bytes.write(to: utm.appendingPathComponent("Data/\(file)")) }
        return utm
    }

    private func raw(_ s: String) -> Data { Data(s.utf8) + Data(count: 4096 - s.utf8.count) }

    func testAppleLinuxVM() throws {
        let utm = try makeUTM("Debian", [
            "Backend": "Apple", "ConfigurationVersion": 4,
            "Information": ["Name": "Debian Box", "Icon": "debian", "IconCustom": false],
            "System": ["Architecture": "aarch64", "CPUCount": 2, "MemorySize": 3072,
                       "Boot": ["OperatingSystem": "Linux", "UEFIBoot": true],
                       "GenericPlatform": ["machineIdentifier": Data([1, 2, 3])]],
            "Virtualization": ["Rosetta": true],
            "Drive": [["ImageName": "AAAA.img", "Identifier": UUID().uuidString, "ReadOnly": false],
                      ["Identifier": UUID().uuidString, "ReadOnly": true]],
            "Network": [["Mode": "Shared", "MacAddress": "AA:BB:CC:DD:EE:01"]],
            "Display": [["WidthPixels": 1920, "HeightPixels": 1080, "PixelsPerInch": 110]],
        ], data: ["AAAA.img": raw("root disk"), "efi_vars.fd": Data("vars".utf8)])

        let r = try UTMImporter.importVM(utm, name: nil)
        let c = try r.bundle.loadConfig()
        XCTAssertEqual(c.name, "Debian Box")
        XCTAssertEqual(c.guestOS, .linux)
        XCTAssertEqual(c.effectiveBackend, .vz)
        XCTAssertEqual(c.cpuCount, 2)
        XCTAssertEqual(c.memoryMiB, 3072)
        XCTAssertEqual(c.network.macAddress, "aa:bb:cc:dd:ee:01")
        XCTAssertTrue(c.features.rosetta)
        XCTAssertEqual(c.boot, .efi)
        XCTAssertEqual(c.disks.map(\.path), ["disk.img"])
        XCTAssertEqual(try Data(contentsOf: r.bundle.resolve("disk.img")).prefix(9), Data("root disk".utf8))
        XCTAssertEqual(try Data(contentsOf: r.bundle.nvramURL), Data("vars".utf8))
        XCTAssertEqual(try Data(contentsOf: r.bundle.machineIdentifierURL), Data([1, 2, 3]))
        XCTAssertTrue(r.notes.contains { $0.contains("external drive") })
        XCTAssertTrue(fm.fileExists(atPath: utm.appendingPathComponent("Data/AAAA.img").path), "the source bundle is untouched")
    }

    func testQEMUWindowsVM() throws {
        let utm = try makeUTM("Win", [
            "Backend": "QEMU", "ConfigurationVersion": 4,
            "Information": ["Name": "Windows 11", "Icon": "windows-11", "IconCustom": false],
            "System": ["Architecture": "aarch64", "CPUCount": 0, "MemorySize": 8192, "Target": "virt"],
            "QEMU": ["UEFIBoot": true, "TPMDevice": true],
            "Drive": [["ImageName": "win.qcow2", "ImageType": "Disk", "Interface": "NVMe", "Identifier": UUID().uuidString],
                      ["ImageName": "virtio.iso", "ImageType": "CD", "Interface": "USB", "Identifier": UUID().uuidString]],
            "Network": [["Mode": "Host", "Hardware": "virtio-net-pci", "MacAddress": "AA:BB:CC:DD:EE:02"]],
        ], data: ["virtio.iso": Data("iso".utf8), "efi_vars.fd": Data("vars".utf8), "tpmdata": Data("tpm".utf8)])
        // A real qcow2 image so the conversion path runs.
        let qemuImg = URL(fileURLWithPath: "/opt/homebrew/bin/qemu-img")
        guard fm.isExecutableFile(atPath: qemuImg.path) else { throw XCTSkip("qemu-img not installed") }
        let p = Process()
        p.executableURL = qemuImg
        p.arguments = ["create", "-q", "-f", "qcow2", utm.appendingPathComponent("Data/win.qcow2").path, "64M"]
        try p.run(); p.waitUntilExit()

        let r = try UTMImporter.importVM(utm, name: "w")
        let c = try r.bundle.loadConfig()
        XCTAssertEqual(c.guestOS, .windows)
        XCTAssertEqual(c.effectiveBackend, .qemu)
        XCTAssertEqual(c.effectiveArchitecture, .aarch64)
        XCTAssertEqual(c.network.mode, .hostOnly)
        XCTAssertEqual(c.disks.count, 1, "the CD is left out")
        XCTAssertEqual(DiskImage.virtualSize(of: r.bundle.resolve("disk.img")), 64 << 20)
        XCTAssertEqual(try Data(contentsOf: r.bundle.efiVarsURL), Data("vars".utf8))
        XCTAssertEqual(try Data(contentsOf: r.bundle.tpmStateDirectory.appendingPathComponent("tpm2-00.permall")), Data("tpm".utf8))
        XCTAssertTrue(r.notes.contains { $0.contains("CD image") })
    }

    func testBridgedNetworkKeepsItsInterface() throws {
        let utm = try makeUTM("Bridged", [
            "Backend": "Apple", "ConfigurationVersion": 4,
            "Information": ["Name": "Bridged"],
            "System": ["Architecture": "aarch64", "CPUCount": 2, "MemorySize": 2048,
                       "Boot": ["OperatingSystem": "Linux", "UEFIBoot": true]],
            "Drive": [["ImageName": "disk.img", "Identifier": UUID().uuidString]],
            "Network": [["Mode": "Bridged", "BridgeInterface": "en7", "MacAddress": "AA:BB:CC:DD:EE:03"]],
        ], data: ["disk.img": raw("linux")])
        let c = try UTMImporter.importVM(utm, name: "b").bundle.loadConfig()
        XCTAssertEqual(c.network.mode, .bridged)
        XCTAssertEqual(c.network.bridgeInterface, "en7")
        XCTAssertEqual(c.network.macAddress, "aa:bb:cc:dd:ee:03")
    }

    func testAppleMacOSVMCarriesItsPlatformIdentity() throws {
        let utm = try makeUTM("Mac", [
            "Backend": "Apple", "ConfigurationVersion": 4,
            "Information": ["Name": "Sonoma"],
            "System": ["Architecture": "aarch64", "CPUCount": 4, "MemorySize": 8192,
                       "Boot": ["OperatingSystem": "macOS", "UEFIBoot": false],
                       "MacPlatform": ["HardwareModel": Data([9]), "MachineIdentifier": Data([8]), "AuxiliaryStoragePath": "AuxiliaryStorage"]],
            "Drive": [["ImageName": "mac.img", "Identifier": UUID().uuidString]],
        ], data: ["mac.img": raw("apfs"), "AuxiliaryStorage": Data("aux".utf8)])
        let r = try UTMImporter.importVM(utm, name: nil)
        XCTAssertEqual(try r.bundle.loadConfig().guestOS, .macOS)
        XCTAssertEqual(try Data(contentsOf: r.bundle.hardwareModelURL), Data([9]))
        XCTAssertEqual(try Data(contentsOf: r.bundle.machineIdentifierURL), Data([8]))
        XCTAssertEqual(try Data(contentsOf: r.bundle.auxiliaryStorageURL), Data("aux".utf8))
    }

    func testRejectsDiskTraversalAndSymlinkEscape() throws {
        let outside = root.appendingPathComponent("private.img")
        try raw("host data").write(to: outside)
        for (index, image) in ["../../private.img", "escape.img", "nested/../disk.img", outside.path].enumerated() {
            let utm = try makeUTM("Escape\(index)", [
                "Backend": "Apple", "ConfigurationVersion": 4,
                "System": ["Boot": ["OperatingSystem": "Linux", "UEFIBoot": true]],
                "Drive": [["ImageName": "disk.img"], ["ImageName": image]],
            ], data: ["disk.img": raw("boot")])
            try fm.createSymbolicLink(at: utm.appendingPathComponent("Data/escape.img"), withDestinationURL: outside)
            XCTAssertThrowsError(try UTMImporter.importVM(utm, name: "escape\(index)")) {
                XCTAssertTrue("\($0)".contains("Data directory"))
            }
        }
    }

    func testRejectsEscapingBootAndPlatformFiles() throws {
        let outside = root.appendingPathComponent("private.bin")
        try Data("host data".utf8).write(to: outside)
        let boots: [[String: Any]] = [
            ["OperatingSystem": "Linux", "UEFIBoot": false, "LinuxKernelPath": "../../private.bin"],
            ["OperatingSystem": "Linux", "UEFIBoot": false, "LinuxKernelPath": "disk.img", "LinuxInitialRamdiskPath": "escape"],
            ["OperatingSystem": "Linux", "UEFIBoot": true, "EfiVariableStoragePath": "escape"],
            ["OperatingSystem": "macOS"],
        ]
        for (index, boot) in boots.enumerated() {
            let utm = try makeUTM("BootEscape\(index)", [
                "Backend": "Apple", "ConfigurationVersion": 4,
                "System": ["Boot": boot, "MacPlatform": ["HardwareModel": Data([1]), "MachineIdentifier": Data([2]),
                                                        "AuxiliaryStoragePath": "escape"]],
                "Drive": [["ImageName": "disk.img"]],
            ], data: ["disk.img": raw("boot")])
            try fm.createSymbolicLink(at: utm.appendingPathComponent("Data/escape"), withDestinationURL: outside)
            XCTAssertThrowsError(try UTMImporter.importVM(utm, name: "bootEscape\(index)")) {
                XCTAssertTrue("\($0)".contains("Data directory"))
            }
        }
    }

    func testRejectsEscapingQEMUPlatformFilesAndDataDirectory() throws {
        let outside = root.appendingPathComponent("host-data")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let hostFile = outside.appendingPathComponent("host.bin")
        try Data("host data".utf8).write(to: hostFile)
        for (index, path) in ["efi_vars.fd", "tpmdata", "Data"].enumerated() {
            let utm = try makeUTM("QEMUEscape\(index)", [
                "Backend": "QEMU", "ConfigurationVersion": 4,
                "System": ["Architecture": "aarch64"],
                "Drive": [["ImageName": "disk.img"]],
            ], data: ["disk.img": raw("boot")])
            let link = path == "Data" ? utm.appendingPathComponent("Data") : utm.appendingPathComponent("Data/\(path)")
            if path == "Data" { try fm.removeItem(at: link) }
            try fm.createSymbolicLink(at: link, withDestinationURL: path == "Data" ? outside : hostFile)
            XCTAssertThrowsError(try UTMImporter.importVM(utm, name: "qemuEscape\(index)")) {
                XCTAssertTrue("\($0)".contains("Data directory"))
            }
        }
    }

    func testRefusals() throws {
        let legacy = try makeUTM("Old", ["ConfigurationVersion": 2], data: [:])
        XCTAssertThrowsError(try UTMImporter.importVM(legacy, name: nil))
        let layered = try makeUTM("Layered", [
            "Backend": "Apple", "ConfigurationVersion": 4, "Information": ["Name": "L"],
            "System": ["Boot": ["OperatingSystem": "Linux", "UEFIBoot": true]],
            "Drive": [["ImageName": "d.img", "Identifier": UUID().uuidString]],
        ], data: ["d.img": raw("base"), "d.img.current.asif": Data("live writes".utf8)])
        XCTAssertThrowsError(try UTMImporter.importVM(layered, name: nil)) { XCTAssertTrue("\($0)".contains("snapshot layers")) }
        let riscv = try makeUTM("RV", [
            "Backend": "QEMU", "ConfigurationVersion": 4, "Information": ["Name": "R"],
            "System": ["Architecture": "riscv64"], "Drive": [],
        ], data: [:])
        XCTAssertThrowsError(try UTMImporter.importVM(riscv, name: nil))
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("library").path).isEmpty, "nothing half-created")
    }
}
