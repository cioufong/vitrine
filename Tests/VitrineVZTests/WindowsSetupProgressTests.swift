import XCTest
import VitrineCore
@testable import VitrineVZ

@MainActor
final class WindowsSetupProgressTests: XCTestCase {
    private func fixture() throws -> VMBundle {
        let bundle = VMBundle(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("vitrine-setup-progress-\(UUID()).vitrinevm"))
        var config = VMConfig(name: "setup", guestOS: .windows)
        config.backend = .qemu
        config.disks = [.init(path: "disk.img")]
        config.installMedia = "windows.iso"
        config.extraMedia = ["seed.iso"]
        try bundle.saveConfig(config)
        for name in ["disk.img", "windows.iso", "seed.iso"] {
            try Data("fixture".utf8).write(to: bundle.resolve(name))
        }
        return bundle
    }

    func testAgentProgressUsesRefreshedMediaConfig() throws {
        let bundle = try fixture()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let controller = try VirtualMachineController(bundle: bundle)
        var latest = try bundle.loadConfig()
        latest.installMedia = nil
        latest.extraMedia = nil
        try bundle.saveConfig(latest)

        controller.noteWindowsSetupProgress()

        let saved = try bundle.loadConfig()
        XCTAssertNil(saved.windowsSetupAgentSeen, "a stale controller must not re-mark an ejected setup")
        XCTAssertFalse(saved.hasInstallMedia)
    }

    func testAgentProgressPersistsForAttachedWindowsSetup() throws {
        let bundle = try fixture()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let controller = try VirtualMachineController(bundle: bundle)

        controller.noteWindowsSetupProgress()

        XCTAssertEqual(try bundle.loadConfig().windowsSetupAgentSeen, true)
        XCTAssertEqual(controller.config.windowsSetupAgentSeen, true)
    }
}
