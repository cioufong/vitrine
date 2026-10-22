import Foundation
import XCTest
@testable import VitrineCore

final class SnapshotIntegrityTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("vitrine-snapshot-integrity-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func makeBundle() throws -> VMBundle {
        var config = VMConfig(name: "integrity")
        config.disks = [.init(path: "disk.img")]
        let bundle = try VMBundle.create(at: root.appendingPathComponent("vm.vitrinevm"), config: config)
        try Data("before".utf8).write(to: bundle.resolve("disk.img"))
        return bundle
    }

    private func save(_ snapshot: Snapshot, at bundle: VMBundle) throws -> URL {
        let dir = bundle.snapshotsDirectory.appendingPathComponent(snapshot.id.uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: dir.appendingPathComponent("snapshot.json"))
        return dir
    }

    private func assertRejectedWithoutMutation(_ bundle: VMBundle, _ snapshot: Snapshot,
                                               file: StaticString = #filePath, line: UInt = #line) throws {
        let beforeConfig = try Data(contentsOf: bundle.configURL)
        try Data("current".utf8).write(to: bundle.resolve("disk.img"))
        try Data("current-ram".utf8).write(to: bundle.savedStateURL)
        XCTAssertThrowsError(try SnapshotStore(bundle: bundle).restore(snapshot.id), file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: bundle.resolve("disk.img")), Data("current".utf8), file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: bundle.savedStateURL), Data("current-ram".utf8), file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: bundle.configURL), beforeConfig, file: file, line: line)
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: bundle.url.path).contains { $0.hasPrefix(".restore-") }, file: file, line: line)
        XCTAssertFalse(bundle.isLocked, file: file, line: line)
    }

    func testCreateRejectsExternalWritableDisksBeforeCreatingSnapshotDirectory() throws {
        let bundle = try makeBundle()
        let external = root.appendingPathComponent("outside.img")
        try Data("external".utf8).write(to: external)
        try fm.createSymbolicLink(at: bundle.resolve("linked.img"), withDestinationURL: external)
        try fm.createSymbolicLink(at: bundle.resolve("linked-dir"), withDestinationURL: root)
        for path in [external.path, "~/vitrine-do-not-read.img", "../outside.img", "linked.img", "linked-dir/outside.img"] {
            var config = try bundle.loadConfig(); config.disks = [.init(path: path)]
            try bundle.saveConfig(config)
            XCTAssertThrowsError(try SnapshotStore(bundle: bundle).create(name: "unsafe"), path)
            XCTAssertFalse(fm.fileExists(atPath: bundle.snapshotsDirectory.path), path)
            XCTAssertEqual(try Data(contentsOf: external), Data("external".utf8))
            XCTAssertFalse(bundle.isLocked)
        }
    }

    func testInternalWritableAndExternalReadOnlyDisksRoundTrip() throws {
        let bundle = try makeBundle()
        let external = root.appendingPathComponent("readonly.iso")
        try Data("external".utf8).write(to: external)
        try fm.createSymbolicLink(at: bundle.resolve("readonly-link.iso"), withDestinationURL: external)
        var config = try bundle.loadConfig()
        config.disks += [.init(path: external.path, readOnly: true), .init(path: "readonly-link.iso", readOnly: true)]
        try bundle.saveConfig(config)
        try Data("memory".utf8).write(to: bundle.savedStateURL)
        let snapshot = try SnapshotStore(bundle: bundle).create(name: "safe")
        XCTAssertTrue(snapshot.includesMemory)
        XCTAssertFalse(snapshot.files.contains("readonly-link.iso"))
        try Data("after".utf8).write(to: bundle.resolve("disk.img"))
        try SnapshotStore(bundle: bundle).restore(snapshot.id)
        XCTAssertEqual(try Data(contentsOf: bundle.resolve("disk.img")), Data("before".utf8))
        XCTAssertEqual(try Data(contentsOf: external), Data("external".utf8))
    }

    func testLegacySnapshotWithExternalWritableDiskIsRejectedBeforeRestore() throws {
        for path in [root.appendingPathComponent("outside.img").path, "~/outside.img", "../outside.img", "linked.img"] {
            let bundle = try makeBundle()
            try fm.createSymbolicLink(at: bundle.resolve("linked.img"), withDestinationURL: root.appendingPathComponent("outside.img"))
            var config = try bundle.loadConfig(); config.disks = [.init(path: path)]
            let snapshot = Snapshot(id: UUID(), name: "legacy", createdAt: Date(), includesMemory: true,
                                    files: ["config.json", "state.vzvmsave"])
            let dir = try save(snapshot, at: bundle)
            try JSONEncoder().encode(config).write(to: dir.appendingPathComponent("config.json"))
            try Data("old-ram".utf8).write(to: dir.appendingPathComponent("state.vzvmsave"))
            try assertRejectedWithoutMutation(bundle, snapshot)
            try fm.removeItem(at: bundle.url)
        }
    }

    func testManifestMustIncludeConfigWritableDisksAndAccurateMemoryMetadata() throws {
        for variant in 0..<8 {
            let bundle = try makeBundle()
            let store = SnapshotStore(bundle: bundle)
            var snapshot = try store.create(name: "original")
            switch variant {
            case 0: snapshot.files.removeAll { $0 == "disk.img" }
            case 1: snapshot.files.removeAll { $0 == "config.json" }
            case 2: snapshot.includesMemory = true
            case 3:
                snapshot.files.append("state.vzvmsave")
                try Data("old".utf8).write(to: bundle.snapshotsDirectory.appendingPathComponent(snapshot.id.uuidString).appendingPathComponent("state.vzvmsave"))
            case 4: snapshot.files.append("state.usb")
                try Data().write(to: bundle.snapshotsDirectory.appendingPathComponent(snapshot.id.uuidString).appendingPathComponent("state.usb"))
            case 5:
                // The saved RAM is on disk but missing from the manifest/flag.
                try Data("old".utf8).write(to: bundle.snapshotsDirectory.appendingPathComponent(snapshot.id.uuidString).appendingPathComponent("state.vzvmsave"))
            case 6:
                snapshot.includesMemory = true
                snapshot.files += ["state.vzvmsave", "state.qemusave"]
                for file in ["state.vzvmsave", "state.qemusave"] {
                    try Data("old".utf8).write(to: bundle.snapshotsDirectory.appendingPathComponent(snapshot.id.uuidString).appendingPathComponent(file))
                }
            default:
                try fm.removeItem(at: bundle.snapshotsDirectory.appendingPathComponent(snapshot.id.uuidString).appendingPathComponent("disk.img"))
            }
            _ = try save(snapshot, at: bundle)
            try assertRejectedWithoutMutation(bundle, snapshot)
            try fm.removeItem(at: bundle.url)
        }
    }

    func testManifestRejectsTraversalAbsoluteReservedAndOverlappingEntries() throws {
        for path in ["../outside.img", root.appendingPathComponent("outside.img").path, "~/outside.img", "run.lock", "snapshots/other", "disk.img/child", "disk.img", "unlisted.img"] {
            let bundle = try makeBundle()
            var snapshot = try SnapshotStore(bundle: bundle).create(name: "original")
            snapshot.files.append(path)
            let dir = try save(snapshot, at: bundle)
            if path == "unlisted.img" { try Data("unexpected".utf8).write(to: dir.appendingPathComponent(path)) }
            try assertRejectedWithoutMutation(bundle, snapshot)
            try fm.removeItem(at: bundle.url)
        }
    }

    func testRestoreRejectsSourceAndDestinationSymlinks() throws {
        for source in [true, false] {
            let bundle = try makeBundle()
            let snapshot = try SnapshotStore(bundle: bundle).create(name: "original")
            let external = root.appendingPathComponent("outside.img")
            try Data("external".utf8).write(to: external)
            let link = source ? bundle.snapshotsDirectory.appendingPathComponent(snapshot.id.uuidString).appendingPathComponent("disk.img") : bundle.resolve("disk.img")
            try fm.removeItem(at: link)
            try fm.createSymbolicLink(at: link, withDestinationURL: external)
            XCTAssertThrowsError(try SnapshotStore(bundle: bundle).restore(snapshot.id))
            XCTAssertEqual(try Data(contentsOf: external), Data("external".utf8))
            XCTAssertFalse(bundle.isLocked)
            try fm.removeItem(at: bundle.url)
        }
    }

    func testCreateRejectsMissingWritableDiskAndNestedStateSymlink() throws {
        let bundle = try makeBundle()
        try fm.removeItem(at: bundle.resolve("disk.img"))
        XCTAssertThrowsError(try SnapshotStore(bundle: bundle).create(name: "missing"))
        XCTAssertFalse(fm.fileExists(atPath: bundle.snapshotsDirectory.path))
        try Data("disk".utf8).write(to: bundle.resolve("disk.img"))
        try fm.createDirectory(at: bundle.tpmStateDirectory, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: bundle.tpmStateDirectory.appendingPathComponent("outside"), withDestinationURL: root)
        XCTAssertThrowsError(try SnapshotStore(bundle: bundle).create(name: "linked-state"))
        XCTAssertFalse(fm.fileExists(atPath: bundle.snapshotsDirectory.path))
    }

    func testSavedWritableUSBImagesAndHostDevicesAreRefused() throws {
        let bundle = try makeBundle()
        try Data("memory".utf8).write(to: bundle.savedStateURL)
        let cases: [USBAttachment] = [
            .image(path: root.appendingPathComponent("usb.img").path, readOnly: false),
            .host(HostUSBDevice(vendorID: 1, productID: 2, locationID: 3, address: 4, registryID: 5))
        ]
        for attachment in cases {
            try JSONEncoder().encode([attachment]).write(to: bundle.suspendedUSBURL)
            XCTAssertThrowsError(try SnapshotStore(bundle: bundle).create(name: "usb"))
            XCTAssertFalse(fm.fileExists(atPath: bundle.snapshotsDirectory.path))
        }
    }

    func testLegacySavedWritableUSBAndMalformedUSBMetadataAreRefusedOnRestore() throws {
        for malformed in [false, true] {
            let bundle = try makeBundle()
            let snapshot = Snapshot(id: UUID(), name: "usb-legacy", createdAt: Date(), includesMemory: true,
                files: ["config.json", "disk.img", "state.vzvmsave", "usb-attachments.json"])
            let dir = try save(snapshot, at: bundle)
            try Data(contentsOf: bundle.configURL).write(to: dir.appendingPathComponent("config.json"))
            try Data("old-disk".utf8).write(to: dir.appendingPathComponent("disk.img"))
            try Data("old-ram".utf8).write(to: dir.appendingPathComponent("state.vzvmsave"))
            let usb = malformed ? Data("invalid".utf8) : try JSONEncoder().encode([
                USBAttachment.image(path: root.appendingPathComponent("usb.img").path, readOnly: false)])
            try usb.write(to: dir.appendingPathComponent("usb-attachments.json"))
            try assertRejectedWithoutMutation(bundle, snapshot)
            try fm.removeItem(at: bundle.url)
        }
    }

    func testSnapshotDirectorySymlinkAndManifestIDMismatchAreRefused() throws {
        let bundle = try makeBundle()
        try fm.createSymbolicLink(at: bundle.snapshotsDirectory, withDestinationURL: root)
        XCTAssertThrowsError(try SnapshotStore(bundle: bundle).create(name: "external-snapshots"))
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: root.path).allSatisfy { $0 == "vm.vitrinevm" })
        try fm.removeItem(at: bundle.snapshotsDirectory)
        let snapshot = try SnapshotStore(bundle: bundle).create(name: "valid")
        let dir = bundle.snapshotsDirectory.appendingPathComponent(snapshot.id.uuidString)
        var mismatched = snapshot; mismatched.id = UUID()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(mismatched).write(to: dir.appendingPathComponent("snapshot.json"))
        try assertRejectedWithoutMutation(bundle, snapshot)
    }

    func testSavedMemoryMustBeARegularFile() throws {
        let bundle = try makeBundle()
        try fm.createDirectory(at: bundle.savedStateURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try SnapshotStore(bundle: bundle).create(name: "directory-memory"))
        try fm.removeItem(at: bundle.savedStateURL)
        let snapshot = Snapshot(id: UUID(), name: "invalid-memory", createdAt: Date(), includesMemory: true,
            files: ["config.json", "disk.img", "state.vzvmsave"])
        let dir = try save(snapshot, at: bundle)
        try Data(contentsOf: bundle.configURL).write(to: dir.appendingPathComponent("config.json"))
        try Data("old".utf8).write(to: dir.appendingPathComponent("disk.img"))
        try fm.createDirectory(at: dir.appendingPathComponent("state.vzvmsave"), withIntermediateDirectories: true)
        try assertRejectedWithoutMutation(bundle, snapshot)
    }

    func testCloneRejectsExternalWritableReferencesBeforeCreatingDestination() throws {
        let bundle = try makeBundle()
        let external = root.appendingPathComponent("outside.img")
        try Data("external".utf8).write(to: external)
        try fm.createSymbolicLink(at: bundle.resolve("linked.img"), withDestinationURL: external)
        try fm.createSymbolicLink(at: bundle.resolve("linked-dir"), withDestinationURL: root)
        for path in [external.path, "~/vitrine-do-not-read.img", "../outside.img", "linked.img", "linked-dir/outside.img"] {
            var config = try bundle.loadConfig(); config.disks = [.init(path: path)]
            try bundle.saveConfig(config)
            let parent = root.appendingPathComponent("must-not-exist")
            let destination = parent.appendingPathComponent("copy.vitrinevm")
            XCTAssertThrowsError(try VMCloner.clone(bundle, to: destination, newName: "copy"), path)
            XCTAssertFalse(fm.fileExists(atPath: parent.path), path)
            XCTAssertEqual(try Data(contentsOf: external), Data("external".utf8))
            XCTAssertFalse(bundle.isLocked)
            try? fm.removeItem(at: parent)
        }
    }

    func testClonePreservesExternalReadOnlyReferencesWithoutCapturingThem() throws {
        let bundle = try makeBundle()
        let external = root.appendingPathComponent("outside.iso")
        try Data("external".utf8).write(to: external)
        try fm.createSymbolicLink(at: bundle.resolve("readonly.iso"), withDestinationURL: external)
        var config = try bundle.loadConfig()
        config.disks += [.init(path: external.path, readOnly: true), .init(path: "../outside.iso", readOnly: true),
                         .init(path: "readonly.iso", readOnly: true)]
        try bundle.saveConfig(config)
        let clone = try VMCloner.clone(bundle, to: root.appendingPathComponent("copy.vitrinevm"), newName: "copy")
        XCTAssertEqual(try Data(contentsOf: clone.resolve("disk.img")), Data("before".utf8))
        let clonedConfig = try clone.loadConfig()
        XCTAssertEqual(clonedConfig.disks[0], config.disks[0])
        XCTAssertEqual(clonedConfig.disks.dropFirst().map(\.path), Array(repeating: external.resolvingSymlinksInPath().path, count: 3))
        XCTAssertTrue(clonedConfig.disks.dropFirst().allSatisfy(\.readOnly))
        XCTAssertEqual(try Data(contentsOf: external), Data("external".utf8))
    }

    func testDeleteRejectsExternalSnapshotDirectoryWithoutDeletingItsContents() throws {
        let bundle = try makeBundle()
        let store = SnapshotStore(bundle: bundle)
        let snapshot = try store.create(name: "safe")
        let external = root.appendingPathComponent("external-snapshots")
        try fm.moveItem(at: bundle.snapshotsDirectory, to: external)
        try fm.createSymbolicLink(at: bundle.snapshotsDirectory, withDestinationURL: external)
        XCTAssertThrowsError(try store.delete(snapshot.id))
        XCTAssertTrue(fm.fileExists(atPath: external.appendingPathComponent(snapshot.id.uuidString).appendingPathComponent("snapshot.json").path))
        XCTAssertFalse(bundle.isLocked)
    }

    func testDeleteRequiresTheExclusiveBundleLock() throws {
        let bundle = try makeBundle()
        let store = SnapshotStore(bundle: bundle)
        let snapshot = try store.create(name: "safe")
        try bundle.acquireRunLock()
        XCTAssertThrowsError(try store.delete(snapshot.id))
        XCTAssertTrue(fm.fileExists(atPath: bundle.snapshotsDirectory.appendingPathComponent(snapshot.id.uuidString).path))
        XCTAssertTrue(bundle.isLocked)
        bundle.releaseRunLock()
        XCTAssertNoThrow(try store.delete(snapshot.id))
        XCTAssertTrue(store.list().isEmpty)
    }

    func testReservedDiskPathsAreRejectedRegardlessOfCase() throws {
        for path in ["CONFIG.JSON", "RUN.LOCK", "SNAPSHOTS/unused.img", "State.VZVMsave", "TPM/data", "guest-account.secret"] {
            let bundle = try makeBundle()
            try Data("secret".utf8).write(to: bundle.resolve("guest-account.secret"))
            var config = try bundle.loadConfig(); config.disks = [.init(path: path)]
            try bundle.saveConfig(config)
            XCTAssertThrowsError(try SnapshotStore(bundle: bundle).create(name: "reserved"), path)
            XCTAssertFalse(fm.fileExists(atPath: bundle.snapshotsDirectory.path), path)
            let parent = root.appendingPathComponent("must-not-exist")
            XCTAssertThrowsError(try VMCloner.clone(bundle, to: parent.appendingPathComponent("copy.vitrinevm"), newName: "copy"), path)
            XCTAssertFalse(fm.fileExists(atPath: parent.path), path)
            try? fm.removeItem(at: parent)
            try fm.removeItem(at: bundle.url)
        }
    }

    func testFailedRollbackPreservesOriginalBackupsAndReportsRecoveryLocation() throws {
        for replaceInstalledDisk in [false, true] {
            let bundle = try makeBundle()
            let snapshot = try SnapshotStore(bundle: bundle).create(name: "before")
            try Data("original-current-disk".utf8).write(to: bundle.resolve("disk.img"))
            let store = SnapshotStore(bundle: bundle, fileManagerFactory: {
                RestoreCollisionFileManager(bundle: bundle, replaceInstalledDisk: replaceInstalledDisk)
            })
            var restoreError: Error?
            do { try store.restore(snapshot.id) } catch { restoreError = error }
            XCTAssertNotNil(restoreError)
            let workspace = try XCTUnwrap(fm.contentsOfDirectory(at: bundle.url, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix(".restore-") })
            let backup = workspace.appendingPathComponent("old/disk.img")
            XCTAssertEqual(try Data(contentsOf: backup), Data("original-current-disk".utf8), "the only original disk must survive failed rollback")
            XCTAssertEqual(try Data(contentsOf: bundle.resolve("disk.img")), Data("concurrent-disk".utf8), "rollback must not overwrite concurrent destination state")
            XCTAssertTrue(restoreError?.localizedDescription.contains(workspace.lastPathComponent + "/old") == true,
                          "error must include the preserved original-state directory: \(restoreError?.localizedDescription ?? "none")")
            XCTAssertTrue(restoreError?.localizedDescription.localizedCaseInsensitiveContains("rollback") == true)
            XCTAssertThrowsError(try SnapshotStore(bundle: bundle).restore(snapshot.id), "an incomplete recovery must block a silent retry")
            XCTAssertEqual(try Data(contentsOf: bundle.resolve("disk.img")), Data("concurrent-disk".utf8))
            XCTAssertFalse(bundle.isLocked)
            try fm.removeItem(at: bundle.url)
        }
    }

    func testSuccessfulRollbackRecoversOriginalsAndRemovesWorkspace() throws {
        let bundle = try makeBundle()
        let snapshot = try SnapshotStore(bundle: bundle).create(name: "before")
        let originalConfig = try Data(contentsOf: bundle.configURL)
        try Data("original-current-disk".utf8).write(to: bundle.resolve("disk.img"))
        let store = SnapshotStore(bundle: bundle, fileManagerFactory: { MissingStagedConfigFileManager() })
        XCTAssertThrowsError(try store.restore(snapshot.id))
        XCTAssertEqual(try Data(contentsOf: bundle.resolve("disk.img")), Data("original-current-disk".utf8))
        XCTAssertEqual(try Data(contentsOf: bundle.configURL), originalConfig)
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: bundle.url.path).contains { $0.hasPrefix(".restore-") })
        XCTAssertFalse(bundle.isLocked)
    }

    func testUnfinishedRecoveryBlocksAppAndCLIStartWithoutLeakingTheLock() throws {
        let bundle = try makeBundle()
        let recovery = bundle.url.appendingPathComponent(".restore-\(UUID().uuidString)")
        let backup = recovery.appendingPathComponent("old/disk.img")
        try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("recoverable-original".utf8).write(to: backup)
        let priorOwner = Data("prior-owner\n".utf8)
        for role: VMBundle.LockRole? in [.cli, .app, nil] {
            try priorOwner.write(to: bundle.lockURL)
            let descriptorsBefore = try fm.contentsOfDirectory(atPath: "/dev/fd").count
            XCTAssertThrowsError(try bundle.acquireRunLock(role: role)) { error in
                XCTAssertTrue(error.localizedDescription.contains(recovery.lastPathComponent))
            }
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: "/dev/fd").count, descriptorsBefore, "rejected startup must close its descriptor")
            XCTAssertEqual(try Data(contentsOf: bundle.lockURL), priorOwner, "rejection must occur before publishing ownership")
            XCTAssertFalse(bundle.isLocked, "failed startup must release flock and its descriptor")
            XCTAssertNil(bundle.runningPID())
            bundle.releaseRunLock() // Also clean up the pre-fix success so later assertions remain independent.
            XCTAssertNoThrow(try bundle.acquireRunLock(role: .operation), "manual recovery operations must remain available")
            XCTAssertTrue(bundle.isLocked)
            bundle.releaseRunLock()
            XCTAssertFalse(bundle.isLocked)
            XCTAssertEqual(try Data(contentsOf: backup), Data("recoverable-original".utf8))
        }
        try fm.removeItem(at: recovery)
        for role: VMBundle.LockRole in [.cli, .app] {
            XCTAssertNoThrow(try bundle.acquireRunLock(role: role), "startup may continue after explicit recovery")
            bundle.releaseRunLock()
        }
    }

    func testSavedReadOnlyUSBImagesRemainSupported() throws {
        let bundle = try makeBundle()
        try Data("memory".utf8).write(to: bundle.savedStateURL)
        try JSONEncoder().encode([USBAttachment.image(path: root.appendingPathComponent("readonly.iso").path, readOnly: true)])
            .write(to: bundle.suspendedUSBURL)
        let snapshot = try SnapshotStore(bundle: bundle).create(name: "readonly-usb")
        XCTAssertTrue(snapshot.files.contains("usb-attachments.json"))
        XCTAssertNoThrow(try SnapshotStore(bundle: bundle).restore(snapshot.id))
    }

    func testRestoreRemovesFirmwareStateTheSnapshotDoesNotHave() throws {
        let bundle = try makeBundle()
        let snapshot = try SnapshotStore(bundle: bundle).create(name: "no-firmware-state")
        XCTAssertFalse(snapshot.files.contains("efivars.secureboot"))
        // Secure Boot was enabled after the snapshot: its marker must not survive beside reverted variables.
        try Data("vars".utf8).write(to: bundle.resolve("efivars.fd"))
        try Data("microsoft".utf8).write(to: bundle.resolve("efivars.secureboot"))
        try SnapshotStore(bundle: bundle).restore(snapshot.id)
        XCTAssertFalse(fm.fileExists(atPath: bundle.resolve("efivars.fd").path))
        XCTAssertFalse(fm.fileExists(atPath: bundle.resolve("efivars.secureboot").path))
    }
}

/// Exercises real FileManager EEXIST failures at the filesystem boundary. Production receives an
/// ordinary FileManager dependency; only this test subclass creates a concurrent destination.
private final class RestoreCollisionFileManager: FileManager {
    private let bundle: VMBundle
    private let replaceInstalledDisk: Bool
    private var collided = false

    init(bundle: VMBundle, replaceInstalledDisk: Bool) {
        self.bundle = bundle
        self.replaceInstalledDisk = replaceInstalledDisk
        super.init()
    }

    override func moveItem(at source: URL, to destination: URL) throws {
        let collisionFile = replaceInstalledDisk ? "config.json" : "disk.img"
        if !collided, source.lastPathComponent == collisionFile, source.deletingLastPathComponent().lastPathComponent == "new" {
            collided = true
            try Data("concurrent-disk".utf8).write(to: bundle.resolve("disk.img"), options: .atomic)
            if replaceInstalledDisk { try Data("concurrent-config".utf8).write(to: destination, options: .atomic) }
        }
        try super.moveItem(at: source, to: destination)
    }
}

private final class MissingStagedConfigFileManager: FileManager {
    override func moveItem(at source: URL, to destination: URL) throws {
        if source.lastPathComponent == "config.json", source.deletingLastPathComponent().lastPathComponent == "new" {
            try removeItem(at: source) // A real ENOENT at installation, with no recovery collision.
        }
        try super.moveItem(at: source, to: destination)
    }
}
