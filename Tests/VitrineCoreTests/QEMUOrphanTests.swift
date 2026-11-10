import Foundation
import XCTest
@testable import VitrineCore

/// A QEMU left running by a Vitrine process that died is ended by whoever next takes the bundle's
/// lock, even after the bundle moved; nothing that isn't provably that orphan is ever signalled.
final class QEMUOrphanTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    /// Fake process table: signals end a process unless it ignores them.
    final class Processes: @unchecked Sendable {
        private let lock = NSLock()
        private var table: [pid_t: QEMUOrphan.Inspector.Facts] = [:]
        private var stubborn: Set<pid_t> = []
        private(set) var signals: [(pid_t, Int32)] = []
        func add(_ pid: pid_t, _ facts: QEMUOrphan.Inspector.Facts, ignoresSIGTERM: Bool = false) {
            lock.lock(); table[pid] = facts; if ignoresSIGTERM { stubborn.insert(pid) }; lock.unlock()
        }
        func isAlive(_ pid: pid_t) -> Bool { lock.lock(); defer { lock.unlock() }; return table[pid] != nil }
        var sent: [(pid_t, Int32)] { lock.lock(); defer { lock.unlock() }; return signals }
        var inspector: QEMUOrphan.Inspector {
            var i = QEMUOrphan.Inspector(facts: { pid in self.lock.lock(); defer { self.lock.unlock() }; return self.table[pid] },
                                         signal: { pid, sig in
                                             self.lock.lock(); defer { self.lock.unlock() }
                                             self.signals.append((pid, sig))
                                             if sig == SIGKILL || !self.stubborn.contains(pid) { self.table[pid] = nil }
                                         })
            i.pollInterval = 0.01
            return i
        }
    }

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("vitrine-orphan-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        QEMUOrphan.lockInspector = .system
        try? fm.removeItem(at: root)
    }

    private func makeBundle(_ name: String = "vm") throws -> (VMBundle, UUID) {
        let config = VMConfig(name: name, guestOS: .linux)
        let bundle = try VMBundle.create(at: root.appendingPathComponent("\(name).vitrinevm"), config: config)
        return (bundle, config.id)
    }

    private func qemu(launchedFrom bundle: VMBundle, parent: pid_t = 1, start: UInt64 = 1000,
                      exe: String = "/opt/homebrew/bin/qemu-system-aarch64") -> QEMUOrphan.Inspector.Facts {
        .init(startTime: start, parent: parent, executable: exe,
              arguments: [exe, "-drive", "if=pflash,file=\(bundle.url.path)/efivars.fd"])
    }

    func testTakingTheLockForAnOperationEndsTheOrphanEvenAfterAMove() throws {
        let (original, id) = try makeBundle()
        let procs = Processes()
        procs.add(4242, qemu(launchedFrom: original))
        QEMUOrphan.record(pid: 4242, bundle: original, id: id, inspector: procs.inspector)
        defer { try? fm.removeItem(at: QEMUOrphan.recordURL(for: id)) }

        let moved = VMBundle(url: root.appendingPathComponent("renamed.vitrinevm"))
        try fm.moveItem(at: original.url, to: moved.url)
        QEMUOrphan.lockInspector = procs.inspector
        try moved.withExclusiveLock {} // a snapshot, clone, delete…

        XCTAssertFalse(procs.isAlive(4242))
        XCTAssertEqual(procs.sent.map(\.1), [SIGTERM])
        XCTAssertFalse(fm.fileExists(atPath: QEMUOrphan.recordURL(for: id).path))
        XCTAssertTrue(((try? String(contentsOf: moved.logURL, encoding: .utf8)) ?? "").contains("left running"))
    }

    func testEscalatesToSIGKILL() throws {
        let (bundle, id) = try makeBundle()
        let procs = Processes()
        procs.add(4242, qemu(launchedFrom: bundle), ignoresSIGTERM: true)
        QEMUOrphan.record(pid: 4242, bundle: bundle, id: id, inspector: procs.inspector)
        var i = procs.inspector
        i.pollInterval = 0.5 // 5 s of SIGTERM grace is 10 polls
        XCTAssertNotNil(QEMUOrphan.reap(bundle: bundle, id: id, inspector: i))
        XCTAssertEqual(procs.sent.map(\.1), [SIGTERM, SIGKILL])
    }

    func testNeverSignalsAQEMUWithALiveOwner() throws {
        let (bundle, id) = try makeBundle()
        let procs = Processes()
        procs.add(4242, qemu(launchedFrom: bundle, parent: 777)) // e.g. a Finder copy running elsewhere
        QEMUOrphan.record(pid: 4242, bundle: bundle, id: id, inspector: procs.inspector)
        defer { try? fm.removeItem(at: QEMUOrphan.recordURL(for: id)) }
        XCTAssertNil(QEMUOrphan.reap(bundle: bundle, id: id, inspector: procs.inspector))
        XCTAssertTrue(procs.sent.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: QEMUOrphan.recordURL(for: id).path), "its owner's record stays")
    }

    func testNeverSignalsAReusedPID() throws {
        let (bundle, id) = try makeBundle()
        let procs = Processes()
        procs.add(4242, qemu(launchedFrom: bundle))
        QEMUOrphan.record(pid: 4242, bundle: bundle, id: id, inspector: procs.inspector)
        // The pid now belongs to: a different process start, a non-QEMU, a QEMU of another VM.
        for facts in [qemu(launchedFrom: bundle, start: 2000),
                      qemu(launchedFrom: bundle, exe: "/usr/bin/tail"),
                      qemu(launchedFrom: VMBundle(url: root.appendingPathComponent("other.vitrinevm")))] {
            procs.add(4242, facts)
            QEMUOrphan.record(pid: 4242, bundle: bundle, id: id, inspector: QEMUOrphan.Inspector(
                facts: { _ in self.qemu(launchedFrom: bundle) }, signal: { _, _ in }))
            XCTAssertNil(QEMUOrphan.reap(bundle: bundle, id: id, inspector: procs.inspector))
            XCTAssertTrue(procs.sent.isEmpty, "\(facts)")
        }
        try? fm.removeItem(at: QEMUOrphan.recordURL(for: id))
    }

    func testFindsRecordsFromOlderVersions() throws {
        let (bundle, _) = try makeBundle()
        let procs = Processes()
        procs.add(4242, qemu(launchedFrom: bundle))
        try fm.createDirectory(at: bundle.socketDirectory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: bundle.socketDirectory) }
        try "4242 1000".write(to: QEMUOrphan.legacyRecordURL(for: bundle), atomically: true, encoding: .utf8)
        XCTAssertNotNil(QEMUOrphan.reap(bundle: bundle, id: nil, inspector: procs.inspector))
        XCTAssertFalse(procs.isAlive(4242))
    }

    func testANewerRunsRecordIsNotRemovedByAnOldExit() throws {
        let (bundle, id) = try makeBundle()
        let procs = Processes()
        procs.add(5000, qemu(launchedFrom: bundle))
        QEMUOrphan.record(pid: 5000, bundle: bundle, id: id, inspector: procs.inspector)
        defer { try? fm.removeItem(at: QEMUOrphan.recordURL(for: id)) }
        QEMUOrphan.removeRecord(id: id, bundle: bundle, pid: 4242)
        XCTAssertTrue(fm.fileExists(atPath: QEMUOrphan.recordURL(for: id).path))
    }

    /// The real process table: this test process's own facts.
    func testReadsThisProcess() throws {
        let f = try XCTUnwrap(QEMUOrphan.systemFacts(getpid()))
        XCTAssertEqual(f.parent, getppid())
        XCTAssertEqual(f.arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent },
                       URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent)
        XCTAssertEqual(f.arguments.count, CommandLine.arguments.count)
    }
}
