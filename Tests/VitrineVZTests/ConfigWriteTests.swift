import XCTest
import VitrineCore
@testable import VitrineVZ

/// Every configuration edit loads the saved file, changes one thing and saves it, so an edit
/// never writes back a stale copy over another writer's change.
@MainActor
final class ConfigWriteTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-configwrite-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func makeBundle() throws -> VMBundle {
        var config = VMConfig(name: "vm", guestOS: .linux, cpuCount: 2, memoryMiB: 2048)
        config.disks = [.init(path: "disk.img")]
        let bundle = try VMBundle.create(at: root.appendingPathComponent("vm.vitrinevm"), config: config)
        try Data("disk".utf8).write(to: bundle.resolve("disk.img"))
        return bundle
    }

    /// Another writer (vitrinectl set, a second window) changed the notes after this controller
    /// loaded the configuration; switching the clipboard must not undo that.
    func testClipboardSwitchKeepsAnotherWritersChange() throws {
        let bundle = try makeBundle()
        let controller = try VirtualMachineController(bundle: bundle)
        var other = try bundle.loadConfig(); other.notes = "written elsewhere"; try bundle.saveConfig(other)

        try controller.setClipboardSharing(false)

        let saved = try bundle.loadConfig()
        XCTAssertEqual(saved.notes, "written elsewhere")
        XCTAssertFalse(saved.features.clipboard)
        XCTAssertEqual(controller.config.notes, "written elsewhere", "the controller adopts what was saved")
    }

    /// The configuration window's pattern: two edits through stale controllers (two windows, or a
    /// controller that loaded before another writer) each change only their own field.
    func testTwoWritersChangingDifferentFieldsBothPersist() throws {
        let bundle = try makeBundle()
        let a = try VirtualMachineController(bundle: bundle)
        let b = try VirtualMachineController(bundle: bundle)
        try a.updateConfig { $0.notes = "from a" }
        try b.updateConfig { $0.cpuCount = 3 }
        let saved = try bundle.loadConfig()
        XCTAssertEqual(saved.notes, "from a")
        XCTAssertEqual(saved.cpuCount, 3)
        XCTAssertEqual(b.config.notes, "from a")
    }

    func testAnInvalidChangeIsNotSaved() throws {
        let bundle = try makeBundle()
        let controller = try VirtualMachineController(bundle: bundle)
        XCTAssertThrowsError(try controller.updateConfig { $0.cpuCount = 0 })
        XCTAssertEqual(try bundle.loadConfig().cpuCount, 2)
        XCTAssertEqual(controller.config.cpuCount, 2)
    }
}
