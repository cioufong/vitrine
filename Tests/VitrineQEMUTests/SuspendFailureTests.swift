import XCTest
@testable import VitrineQEMU
import VitrineCore

/// A suspend that fails at its very first QMP command (the status query) must still go through
/// recovery, so the owner learns what state the backend is in instead of getting none at all.
final class SuspendFailureTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-suspend-\(UUID())")
        let fm = FileManager.default
        // A stand-in QEMU installation: QEMUEnvironment.detect only checks that the files exist.
        try fm.createDirectory(at: root.appendingPathComponent("qemu/bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("qemu/share/qemu"), withIntermediateDirectories: true)
        let exe = root.appendingPathComponent("qemu/bin/qemu-system-aarch64")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: exe)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        try Data().write(to: root.appendingPathComponent("qemu/share/qemu/edk2-aarch64-code.fd"))
        setenv("VITRINE_QEMU_PREFIX", root.appendingPathComponent("qemu").path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("VITRINE_QEMU_PREFIX")
        try? FileManager.default.removeItem(at: root)
    }

    func testStatusQueryFailureStillReportsARecoveryState() async throws {
        var config = VMConfig(name: "q", guestOS: .linux, cpuCount: 2, memoryMiB: 2048)
        config.backend = .qemu
        let bundle = try VMBundle.create(at: root.appendingPathComponent("q.vitrinevm"), config: config)
        let machine = try QEMUMachine(bundle: bundle, config: config)

        do {
            try await machine.suspend() // no QMP connection: the status query itself fails
            XCTFail("suspend must fail")
        } catch {}

        XCTAssertEqual(machine.suspendFailureState, .unavailable,
                       "the controller must not get nil (which it can't tell from a successful recovery)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.qemuStateURL.path))
    }
}
