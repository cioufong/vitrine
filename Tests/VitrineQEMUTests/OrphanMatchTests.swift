import XCTest
import Darwin
@testable import VitrineQEMU
@testable import VitrineCore

/// The orphan matcher in VitrineCore must recognise the command line VitrineQEMU really builds,
/// and must work against a real, really orphaned QEMU process.
final class OrphanMatchTests: XCTestCase {
    func testMatchesTheArgumentsQEMUIsStartedWith() {
        let env = QEMUEnvironment(binDirectory: URL(fileURLWithPath: "/q/bin"), shareDirectory: URL(fileURLWithPath: "/q/share"))
        for path in ["/vms/plain.vitrinevm", "/vms/with, comma and space.vitrinevm"] {
            let bundle = VMBundle(url: URL(fileURLWithPath: path))
            var config = VMConfig(name: "vm", guestOS: .linux, cpuCount: 2, memoryMiB: 2048)
            config.backend = .qemu
            config.disks = [.init(path: "disk.img")]
            let args = QEMUArguments.build(config: config, bundle: bundle, env: env,
                                           sockets: QEMUSockets(directory: URL(fileURLWithPath: "/tmp/s")), options: .init(withTPM: false))
            let exe = env.system(config.effectiveArchitecture).path
            let facts = QEMUOrphan.Inspector.Facts(startTime: 7, parent: 1, executable: exe, arguments: [exe] + args)
            let inspector = QEMUOrphan.Inspector(facts: { _ in facts }, signal: { _, _ in })
            let record = QEMUOrphan.Record(pid: 4242, startTime: 7, launchPath: bundle.url.path)
            XCTAssertEqual(QEMUOrphan.match(record, inspector: inspector), .orphan, path)
            let elsewhere = QEMUOrphan.Record(pid: 4242, startTime: 7, launchPath: "/vms/other.vitrinevm")
            XCTAssertEqual(QEMUOrphan.match(elsewhere, inspector: inspector), .notOurs, path)
        }
    }

    /// Smoke test with the installed QEMU (skipped without one): orphaned by a shell that exits at
    /// once, it is found, verified with the real process table and ended.
    func testEndsARealOrphanedQEMU() throws {
        let qemu = "/opt/homebrew/bin/qemu-system-aarch64"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: qemu), "QEMU not installed")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-realorphan-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = VMConfig(name: "real", guestOS: .linux)
        let bundle = try VMBundle.create(at: root.appendingPathComponent("real.vitrinevm"), config: config)

        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", #""$0" "$@" </dev/null >/dev/null 2>&1 & echo $!"#, qemu,
                        "-machine", "none", "-nodefaults", "-display", "none", "-S",
                        "-pidfile", bundle.url.appendingPathComponent("qemu-test.pid").path]
        let out = Pipe()
        sh.standardOutput = out
        try sh.run()
        sh.waitUntilExit()
        let pid = try XCTUnwrap(pid_t(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(pid, SIGKILL) }
        // Reparented to launchd once the shell has exited.
        for _ in 0..<50 where QEMUOrphan.systemFacts(pid)?.parent != 1 { usleep(20_000) }
        XCTAssertEqual(QEMUOrphan.systemFacts(pid)?.parent, 1)

        QEMUOrphan.record(pid: pid, bundle: bundle, id: config.id)
        defer { QEMUOrphan.removeRecord(id: config.id, bundle: bundle, pid: pid) }
        XCTAssertNotNil(try bundle.withExclusiveLock { () -> Bool in true })
        for _ in 0..<50 where kill(pid, 0) == 0 { usleep(20_000) }
        XCTAssertNotEqual(kill(pid, 0), 0, "the orphan was ended")
        XCTAssertTrue(((try? String(contentsOf: bundle.logURL, encoding: .utf8)) ?? "").contains("left running"))
    }
}
