import XCTest
@testable import VitrineCore

final class MediaSafetyTests: XCTestCase {
    func testEjectClearsWindowsSetupProgressBeforeAnotherInstallerCanBeAttached() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-media-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = VMBundle(url: root.appendingPathComponent("vm.vitrinevm"))
        try FileManager.default.createDirectory(at: bundle.url, withIntermediateDirectories: true)
        let seed = bundle.resolve("seed.iso")
        try Data("generated seed".utf8).write(to: seed)
        var c = VMConfig(name: "vm", guestOS: .windows)
        c.installMedia = "/installer.iso"
        c.extraMedia = ["seed.iso"]
        c.windowsSetupAgentSeen = true
        c.windowsSetupOffline = true

        c.ejectInstallMedia(in: bundle)
        c.installMedia = "/another-installer.iso"

        XCTAssertNil(c.windowsSetupAgentSeen, "a prior setup must not authorize finalizing a later installation")
        XCTAssertNil(c.windowsSetupOffline, "a later installer has not been provisioned for offline setup")
        XCTAssertFalse(FileManager.default.fileExists(atPath: seed.path))
    }

    func testEjectDoesNotDeleteExternalSeedThroughSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-media-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = VMBundle(url: root.appendingPathComponent("vm.vitrinevm"))
        try FileManager.default.createDirectory(at: bundle.url, withIntermediateDirectories: true)
        let external = root.appendingPathComponent("external.iso")
        try Data("keep".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: bundle.resolve("seed.iso"), withDestinationURL: external)
        var c = VMConfig(name: "vm")
        c.extraMedia = ["seed.iso"]
        c.ejectInstallMedia(in: bundle)
        XCTAssertEqual(try Data(contentsOf: external), Data("keep".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.resolve("seed.iso").path), "external symlink is user-owned media")
    }
}
