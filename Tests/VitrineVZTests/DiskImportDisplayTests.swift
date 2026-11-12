import Foundation
import XCTest
@testable import VitrineVZ
@testable import VitrineCore

/// A bare Windows disk from another tool may lack the virtio display driver, so the VM made from
/// it starts on the plain framebuffer; a Linux disk doesn't need that.
final class DiskImportDisplayTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private var savedHome: String?

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("vitrine-diskimport-\(UUID())")
        try fm.createDirectory(at: root.appendingPathComponent("library"), withIntermediateDirectories: true)
        savedHome = ProcessInfo.processInfo.environment["VITRINE_HOME"]
        setenv("VITRINE_HOME", root.appendingPathComponent("library").path, 1)
    }

    override func tearDownWithError() throws {
        if let savedHome { setenv("VITRINE_HOME", savedHome, 1) } else { unsetenv("VITRINE_HOME") }
        try? fm.removeItem(at: root)
    }

    func testOnlyWindowsDisksStartOnTheBasicDisplay() throws {
        let qemuImg = URL(fileURLWithPath: "/opt/homebrew/bin/qemu-img")
        guard fm.isExecutableFile(atPath: qemuImg.path) else { throw XCTSkip("qemu-img not installed") }
        let disk = root.appendingPathComponent("disk.qcow2")
        let p = Process()
        p.executableURL = qemuImg
        p.arguments = ["create", "-q", "-f", "qcow2", disk.path, "64M"]
        try p.run(); p.waitUntilExit()

        var windows = VMImporter.DiskOptions(name: "disk-win")
        windows.guestOS = .windows
        XCTAssertTrue(try VMImporter.importDisk(disk, windows).loadConfig().display.basicFramebuffer)
        var linux = VMImporter.DiskOptions(name: "disk-linux")
        linux.guestOS = .linux
        linux.architecture = .x86_64
        XCTAssertFalse(try VMImporter.importDisk(disk, linux).loadConfig().display.basicFramebuffer)
    }
}
