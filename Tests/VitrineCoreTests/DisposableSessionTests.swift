import Foundation
import XCTest
@testable import VitrineCore

final class DisposableSessionTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("vitrine-disposable-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func makeBundle(disposable: Bool = true) throws -> VMBundle {
        var config = VMConfig(name: "throwaway")
        config.disks = [.init(path: "disk.img")]
        config.features.disposable = disposable
        let bundle = try VMBundle.create(at: root.appendingPathComponent("vm.vitrinevm"), config: config)
        try Data("baseline".utf8).write(to: bundle.resolve("disk.img"))
        return bundle
    }

    private func disk(_ b: VMBundle) throws -> String { String(decoding: try Data(contentsOf: b.resolve("disk.img")), as: UTF8.self) }

    func testARunsChangesAreDiscardedAndTheBaselineRemoved() throws {
        let b = try makeBundle()
        try b.acquireRunLock(); defer { b.releaseRunLock() }
        let s = DisposableSession(bundle: b)
        try s.begin()
        XCTAssertTrue(s.isPending)
        try Data("changed by the guest".utf8).write(to: b.resolve("disk.img"))
        var c = try b.loadConfig(); c.cpuCount = 3; try b.saveConfig(c)

        XCTAssertTrue(try s.end())
        XCTAssertEqual(try disk(b), "baseline")
        XCTAssertNotEqual(try b.loadConfig().cpuCount, 3)
        XCTAssertFalse(s.isPending)
        XCTAssertTrue(SnapshotStore(bundle: b).list().isEmpty, "baseline snapshot must be deleted")
    }

    func testSwitchingItOffDuringTheRunKeepsTheChanges() throws {
        let b = try makeBundle()
        try b.acquireRunLock(); defer { b.releaseRunLock() }
        let s = DisposableSession(bundle: b)
        try s.begin()
        try Data("keep me".utf8).write(to: b.resolve("disk.img"))
        var c = try b.loadConfig(); c.features.disposable = false; try b.saveConfig(c)

        XCTAssertFalse(try s.end())
        XCTAssertEqual(try disk(b), "keep me")
        XCTAssertFalse(s.isPending)
        XCTAssertTrue(SnapshotStore(bundle: b).list().isEmpty)
    }

    /// A crash leaves the marker behind: the next start rolls back before taking a new baseline.
    func testAnUnfinishedRunIsRolledBackBeforeTheNextOne() throws {
        let b = try makeBundle()
        try b.acquireRunLock(); defer { b.releaseRunLock() }
        try DisposableSession(bundle: b).begin()
        try Data("crashed mid-run".utf8).write(to: b.resolve("disk.img"))

        let next = DisposableSession(bundle: b)
        try next.begin()
        XCTAssertEqual(try disk(b), "baseline")
        XCTAssertEqual(SnapshotStore(bundle: b).list().count, 1, "exactly one baseline")
        try next.end()
    }

    func testCompletedRestoreCanFinishAfterSnapshotDeletion() throws {
        let b = try makeBundle()
        try b.acquireRunLock(); defer { b.releaseRunLock() }
        let s = DisposableSession(bundle: b)
        try s.begin()
        let snap = try XCTUnwrap(SnapshotStore(bundle: b).list().first)
        let marker: [String: Any] = ["snapshot": snap.id.uuidString, "restored": true]
        try JSONSerialization.data(withJSONObject: marker).write(to: s.markerURL, options: .atomic)
        try SnapshotStore(bundle: b, lockHeldByCaller: true).delete(snap.id)
        XCTAssertNoThrow(try s.discard())
        XCTAssertFalse(s.isPending)
        XCTAssertEqual(try disk(b), "baseline")
    }

    func testCompletedRestoreDoesNotRestoreAgain() throws {
        let b = try makeBundle()
        try b.acquireRunLock(); defer { b.releaseRunLock() }
        let s = DisposableSession(bundle: b)
        try s.begin()
        let snap = try XCTUnwrap(SnapshotStore(bundle: b).list().first)
        let marker: [String: Any] = ["snapshot": snap.id.uuidString, "restored": true]
        try JSONSerialization.data(withJSONObject: marker).write(to: s.markerURL, options: .atomic)
        try Data("already restored".utf8).write(to: b.resolve("disk.img"))
        try s.discard()
        XCTAssertEqual(try disk(b), "already restored")
        XCTAssertTrue(SnapshotStore(bundle: b).list().isEmpty)
    }

    func testRefusesASuspendedVMAndNeedsTheLock() throws {
        let b = try makeBundle()
        XCTAssertThrowsError(try DisposableSession(bundle: b).begin(), "must hold the run lock")
        try b.acquireRunLock(); defer { b.releaseRunLock() }
        try Data("ram".utf8).write(to: b.savedStateURL)
        XCTAssertThrowsError(try DisposableSession(bundle: b).begin())
        XCTAssertTrue(SnapshotStore(bundle: b).list().isEmpty)
    }
}
