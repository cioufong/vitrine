import XCTest
@testable import VitrineCore

final class VMConfigTests: XCTestCase {
    func makeConfig() -> VMConfig {
        var c = VMConfig(name: "test", cpuCount: 2, memoryMiB: 4096)
        c.disks = [.init(path: "disk.img")]
        return c
    }

    func testRoundTripJSON() throws {
        var c = makeConfig()
        c.shares = [.init(hostPath: "/tmp", name: "tmp", readOnly: true)]
        c.account = .init(fullName: "Test User", username: "test")
        let data = try JSONEncoder().encode(c)
        XCTAssertEqual(try JSONDecoder().decode(VMConfig.self, from: data), c)
    }

    func testValidationRejectsBadValues() {
        var c = makeConfig()
        XCTAssertNoThrow(try c.validate(hostCPUs: 8, hostMemoryMiB: 16384))
        c.cpuCount = 16
        XCTAssertThrowsError(try c.validate(hostCPUs: 8, hostMemoryMiB: 16384))
        c = makeConfig(); c.memoryMiB = 1024
        XCTAssertThrowsError(try c.validate(hostCPUs: 8, hostMemoryMiB: 16384))
        c = makeConfig(); c.memoryMiB = 32768
        XCTAssertThrowsError(try c.validate(hostCPUs: 8, hostMemoryMiB: 16384))
        c = makeConfig(); c.name = "a/b"
        XCTAssertThrowsError(try c.validate(hostCPUs: 8, hostMemoryMiB: 16384))
        c = makeConfig(); c.disks = []
        XCTAssertThrowsError(try c.validate(hostCPUs: 8, hostMemoryMiB: 16384))
        c = makeConfig(); c.shares = [.init(hostPath: "/tmp", name: "x"), .init(hostPath: "/var", name: "x")]
        XCTAssertThrowsError(try c.validate(hostCPUs: 8, hostMemoryMiB: 16384))
        c = makeConfig(); c.account = .init(fullName: "x", username: "bad name")
        XCTAssertThrowsError(try c.validate(hostCPUs: 8, hostMemoryMiB: 16384))
    }

    func testMACAddressIsLocallyAdministeredUnicast() {
        for _ in 0..<50 {
            let mac = randomMACAddress()
            let first = UInt8(mac.prefix(2), radix: 16)!
            XCTAssertEqual(first & 0x01, 0)
            XCTAssertEqual(first & 0x02, 0x02)
            XCTAssertEqual(mac.split(separator: ":").count, 6)
        }
    }

    func testSizeParsing() {
        XCTAssertEqual(UInt64(sizeString: "64G"), 64 << 30)
        XCTAssertNil(UInt64(sizeString: "1e100G"))
        XCTAssertNil(UInt64(sizeString: "infG"))
        XCTAssertEqual(UInt64(sizeString: "64GB"), 64 << 30)
        XCTAssertEqual(UInt64(sizeString: "64GiB"), 64 << 30)
        XCTAssertEqual(UInt64(sizeString: "512m"), 512 << 20)
        XCTAssertEqual(UInt64(sizeString: "1.5T"), UInt64(1.5 * Double(1 << 40)))
        XCTAssertEqual(UInt64(sizeString: "4096"), 4096)
        XCTAssertNil(UInt64(sizeString: "abc"))
        XCTAssertNil(UInt64(sizeString: "-1G"))
    }
}

final class BundleAndSnapshotTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func makeBundle() throws -> VMBundle {
        var c = VMConfig(name: "vm", cpuCount: 1, memoryMiB: 2048)
        c.disks = [.init(path: "disk.img")]
        let b = try VMBundle.create(at: tmp.appendingPathComponent("vm.vitrinevm"), config: c)
        try DiskImage.create(at: b.resolve("disk.img"), sizeBytes: 64 << 20, format: .raw)
        try Data("aux-v1".utf8).write(to: b.auxiliaryStorageURL)
        return b
    }

    func testCreateLoadConfig() throws {
        let b = try makeBundle()
        XCTAssertEqual(try b.loadConfig().name, "vm")
        XCTAssertThrowsError(try VMBundle.create(at: b.url, config: try b.loadConfig()))
    }

    func testCreateWithPopulateSavesItsConfigOrRollsBack() throws {
        let c = VMConfig(name: "made", cpuCount: 1, memoryMiB: 2048)
        let failed = tmp.appendingPathComponent("failed.vitrinevm")
        XCTAssertThrowsError(try VMBundle.create(at: failed, config: c) { b, _ in
            try Data("half".utf8).write(to: b.resolve("disk.img"))
            throw VitrineError.io("populate failed")
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.path))
        let b = try VMBundle.create(at: tmp.appendingPathComponent("made.vitrinevm"), config: c) { b, config in
            config.disks = [.init(path: try b.createMainDisk(sizeBytes: 1 << 20, format: .raw))]
        }
        XCTAssertEqual(try b.loadConfig().disks.map(\.path), ["disk.img"])
        // An existing bundle is never rolled back: it isn't this creator's.
        XCTAssertThrowsError(try VMBundle.create(at: b.url, config: c) { _, _ in })
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.resolve("disk.img").path))
    }

    func testSavedStateOfEitherBackendIsSeenAndDiscarded() throws {
        let b = try makeBundle()
        XCTAssertFalse(b.hasSavedState)
        for state in [b.savedStateURL, b.qemuStateURL] {
            try Data("ram".utf8).write(to: state)
            try Data().write(to: b.savedStateUSBMarkerURL)
            try Data("[]".utf8).write(to: b.suspendedUSBURL)
            XCTAssertTrue(b.hasSavedState)
            b.discardSavedState()
            XCTAssertFalse(b.hasSavedState)
            for leftover in [b.savedStateUSBMarkerURL, b.suspendedUSBURL] {
                XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
            }
        }
    }

    func testRawDiskIsSparse() throws {
        let b = try makeBundle()
        let attrs = try FileManager.default.attributesOfItem(atPath: b.resolve("disk.img").path)
        XCTAssertEqual((attrs[.size] as? NSNumber)?.uint64Value, 64 << 20)
        XCTAssertLessThan(DiskImage.allocatedSize(of: b.resolve("disk.img")), 1 << 20)
        try DiskImage.resize(at: b.resolve("disk.img"), to: 128 << 20)
        XCTAssertThrowsError(try DiskImage.resize(at: b.resolve("disk.img"), to: 1 << 20))
    }

    func testSnapshotRestoreRevertsDiskAndAux() throws {
        let b = try makeBundle()
        let disk = try FileHandle(forWritingTo: b.resolve("disk.img"))
        try disk.write(contentsOf: Data("before".utf8)); try disk.close()

        let store = SnapshotStore(bundle: b)
        let snap = try store.create(name: "clean")
        XCTAssertFalse(snap.includesMemory)
        XCTAssertEqual(store.list().map(\.name), ["clean"])

        let disk2 = try FileHandle(forWritingTo: b.resolve("disk.img"))
        try disk2.write(contentsOf: Data("AFTER!".utf8)); try disk2.close()
        try Data("aux-v2".utf8).write(to: b.auxiliaryStorageURL)

        try store.restore(snap.id)
        let head = try FileHandle(forReadingFrom: b.resolve("disk.img")).read(upToCount: 6)
        XCTAssertEqual(head, Data("before".utf8))
        XCTAssertEqual(try Data(contentsOf: b.auxiliaryStorageURL), Data("aux-v1".utf8))
        XCTAssertNotNil(store.find("clean"))

        try store.delete(snap.id)
        XCTAssertTrue(store.list().isEmpty)
    }

    func testSnapshotRefusedWhileRunning() throws {
        let b = try makeBundle()
        try b.acquireRunLock()
        defer { b.releaseRunLock() }
        XCTAssertThrowsError(try SnapshotStore(bundle: b).create(name: "x"))
        XCTAssertEqual(b.runningPID(), getpid())
    }

    func testCloneGetsNewIdentity() throws {
        let b = try makeBundle()
        try Data("machine-id".utf8).write(to: b.machineIdentifierURL)
        let clone = try VMCloner.clone(b, to: tmp.appendingPathComponent("copy.vitrinevm"), newName: "copy")
        let a = try b.loadConfig(), c = try clone.loadConfig()
        XCTAssertNotEqual(a.id, c.id)
        XCTAssertNotEqual(a.network.macAddress, c.network.macAddress)
        XCTAssertEqual(c.name, "copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: clone.resolve("disk.img").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: clone.machineIdentifierURL.path))
    }

    func testFileEditsDoNotBypassAnExistingOwner() throws {
        let b = try makeBundle()
        for role: VMBundle.LockRole in [.operation, .app, .cli] {
            try b.acquireRunLock(role: role)
            var edited = false
            XCTAssertThrowsError(try b.withExclusiveLockIfStopped { edited = true })
            XCTAssertFalse(edited)
            b.releaseRunLock()
        }
        XCTAssertNoThrow(try b.withExclusiveLockIfStopped { XCTAssertTrue(b.holdsRunLock) })
        XCTAssertFalse(b.holdsRunLock)
    }

    func testStaleLockIsIgnored() throws {
        let b = try makeBundle()
        try "999999".write(to: b.lockURL, atomically: true, encoding: .utf8)
        XCTAssertNil(b.runningPID())
        XCTAssertNoThrow(try b.acquireRunLock())
        b.releaseRunLock()
        // The file stays (unlinking would let two holders lock different inodes) but is unlocked.
        XCTAssertNil(b.runningPID())
        XCTAssertFalse(b.isLocked)
    }

    /// The lock is a real flock: another process sees it held, and can't take it.
    func testRunLockIsExclusiveAcrossProcesses() throws {
        let b = try makeBundle()
        try b.acquireRunLock()
        XCTAssertEqual(b.lockOwner(), VMBundle.LockOwner(pid: getpid(), role: .cli))
        XCTAssertThrowsError(try b.acquireRunLock())
        let probe = """
        import fcntl, sys
        f = open(sys.argv[1], "r+")
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB); print("free")
        except OSError:
            print("held")
        """
        func otherProcessSees() throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = ["-I", "-c", probe, b.lockURL.path]
            let out = Pipe(); p.standardOutput = out
            try p.run(); p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        XCTAssertEqual(try otherProcessSees(), "held")
        b.releaseRunLock()
        XCTAssertEqual(try otherProcessSees(), "free")
    }

    /// Restoring after the saved state was consumed (resume deletes it) must still work, and must
    /// not leave a newer RAM image of either backend behind.
    func testRestoreHandlesMissingAndStaleMemoryFiles() throws {
        let b = try makeBundle()
        let store = SnapshotStore(bundle: b)
        try Data("ram-v1".utf8).write(to: b.savedStateURL)
        let snap = try store.create(name: "suspended")
        XCTAssertTrue(snap.includesMemory)
        // Resume consumed the VZ state; later a QEMU suspend left its own RAM image.
        try FileManager.default.removeItem(at: b.savedStateURL)
        try Data("newer".utf8).write(to: b.qemuStateURL)
        try Data("disk-v2".utf8).write(to: b.resolve("disk.img"))
        try store.restore(snap.id)
        XCTAssertEqual(try Data(contentsOf: b.savedStateURL), Data("ram-v1".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.qemuStateURL.path))
        XCTAssertFalse(b.isLocked)

        // A stopped snapshot removes every saved RAM image.
        try FileManager.default.removeItem(at: b.savedStateURL)
        let cold = try store.create(name: "cold")
        XCTAssertFalse(cold.includesMemory)
        try Data("ram".utf8).write(to: b.savedStateURL)
        try store.restore(cold.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.savedStateURL.path))
    }

    func testCloneCopiesMediaAndRejectsSharedWritableDisks() throws {
        let b = try makeBundle()
        var config = try b.loadConfig()
        config.extraMedia = ["seed.iso"]
        try b.saveConfig(config)
        try Data("seed".utf8).write(to: b.resolve("seed.iso"))
        try FileManager.default.createDirectory(at: b.tpmStateDirectory, withIntermediateDirectories: true)
        try Data("tpm".utf8).write(to: b.tpmStateDirectory.appendingPathComponent("tpm2-00.permall"))
        let clone = try VMCloner.clone(b, to: tmp.appendingPathComponent("media.vitrinevm"), newName: "media")
        XCTAssertTrue(FileManager.default.fileExists(atPath: clone.resolve("seed.iso").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: clone.tpmStateDirectory.appendingPathComponent("tpm2-00.permall").path))

        config.disks.append(.init(path: tmp.appendingPathComponent("outside.img").path))
        try b.saveConfig(config)
        XCTAssertThrowsError(try VMCloner.clone(b, to: tmp.appendingPathComponent("bad.vitrinevm"), newName: "bad"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("bad.vitrinevm").path))
    }
}

final class GuestNetworkTests: XCTestCase {
    let leases = """
    {
    \tname=old
    \tip_address=192.168.64.2
    \thw_address=1,2:4:6:8:a:c
    \tidentifier=1,2:4:6:8:a:c
    \tlease=0x66000000
    }
    {
    \tname=mac-vm
    \tip_address=192.168.64.7
    \thw_address=1,2:4:6:8:a:c
    \tidentifier=1,2:4:6:8:a:c
    \tlease=0x67000000
    }
    {
    \tname=other
    \tip_address=192.168.64.9
    \thw_address=1,de:ad:be:ef:0:1
    \tlease=0x68000000
    }
    """

    func testFindsNewestLeaseForMAC() {
        XCTAssertEqual(GuestNetwork.ipAddress(forMAC: "02:04:06:08:0a:0c", leases: leases), "192.168.64.7")
        XCTAssertEqual(GuestNetwork.ipAddress(forMAC: "DE:AD:BE:EF:00:01", leases: leases), "192.168.64.9")
        XCTAssertNil(GuestNetwork.ipAddress(forMAC: "02:00:00:00:00:01", leases: leases))
    }
}
