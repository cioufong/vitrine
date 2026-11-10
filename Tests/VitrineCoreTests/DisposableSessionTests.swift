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

    /// While a run is pending its baseline is the only copy of the pre-run state: deleting it (from
    /// the Snapshots list or `vitrinectl snapshot delete`) would make every later start fail.
    func testThePendingBaselineCannotBeDeleted() throws {
        let b = try makeBundle()
        try b.acquireRunLock()
        try DisposableSession(bundle: b).begin()
        b.releaseRunLock() // a crashed run: marker left behind, lock free
        let snap = try XCTUnwrap(SnapshotStore(bundle: b).list().first)
        XCTAssertEqual(DisposableSession(bundle: b).baselineSnapshotID, snap.id)

        XCTAssertThrowsError(try SnapshotStore(bundle: b).delete(snap.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("disposable"), "\(error)")
        }
        XCTAssertEqual(SnapshotStore(bundle: b).list().map(\.id), [snap.id], "baseline must survive")

        // The next start still rolls back and cleans up.
        try Data("crashed mid-run".utf8).write(to: b.resolve("disk.img"))
        try b.acquireRunLock(); defer { b.releaseRunLock() }
        XCTAssertTrue(try DisposableSession(bundle: b).end())
        XCTAssertEqual(try disk(b), "baseline")
        XCTAssertTrue(SnapshotStore(bundle: b).list().isEmpty)
    }

    func testOtherSnapshotsCanStillBeDeletedDuringARun() throws {
        let b = try makeBundle()
        let other = try SnapshotStore(bundle: b).create(name: "mine")
        try b.acquireRunLock()
        try DisposableSession(bundle: b).begin()
        b.releaseRunLock()
        XCTAssertNoThrow(try SnapshotStore(bundle: b).delete(other.id))
    }

    /// A baseline deleted anyway (by an older version, or by hand) leaves nothing to roll back to:
    /// the start must go on with the current state, say so in the VM log, and forget the run.
    func testAMissingBaselineIsNothingToRollBack() throws {
        let b = try makeBundle()
        try b.acquireRunLock(); defer { b.releaseRunLock() }
        try DisposableSession(bundle: b).begin()
        let snap = try XCTUnwrap(SnapshotStore(bundle: b).list().first)
        try fm.removeItem(at: b.url.appendingPathComponent("snapshots/\(snap.id.uuidString)"))
        try Data("crashed mid-run".utf8).write(to: b.resolve("disk.img"))

        let next = DisposableSession(bundle: b)
        XCTAssertNoThrow(try next.begin())
        XCTAssertEqual(try disk(b), "crashed mid-run", "nothing to restore from")
        XCTAssertEqual(SnapshotStore(bundle: b).list().count, 1, "a fresh baseline for this run")
        let log = (try? String(contentsOf: b.logURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("baseline snapshot is missing"), log)
        XCTAssertNoThrow(try next.end())
        XCTAssertFalse(next.isPending)
    }

    /// The path the VM controller takes on start (`isPending` → `end()`): it logs from the result.
    func testEndReportsNothingDiscardedWhenTheBaselineIsMissing() throws {
        let b = try makeBundle()
        try b.acquireRunLock(); defer { b.releaseRunLock() }
        let s = DisposableSession(bundle: b)
        try s.begin()
        let snap = try XCTUnwrap(SnapshotStore(bundle: b).list().first)
        try fm.removeItem(at: b.url.appendingPathComponent("snapshots/\(snap.id.uuidString)"))
        try Data("crashed mid-run".utf8).write(to: b.resolve("disk.img"))

        XCTAssertFalse(try s.end(), "nothing was discarded")
        XCTAssertFalse(s.isPending)
        XCTAssertNil(s.baselineSnapshotID)
        XCTAssertEqual(try disk(b), "crashed mid-run")
        XCTAssertTrue(((try? String(contentsOf: b.logURL, encoding: .utf8)) ?? "").contains("baseline snapshot is missing"))
    }
}
