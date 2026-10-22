import XCTest
@testable import VitrineCore

final class VMCreationJobTests: XCTestCase {
    func testNamesAndUsernames() {
        for good in ["deb", "win11-c", "a.b_c", "X1"] { XCTAssertTrue(VMCreationJob.isValidVMName(good), good) }
        for bad in ["", "-x", ".hidden", "a/b", "a b", "../up", String(repeating: "a", count: 65)] {
            XCTAssertFalse(VMCreationJob.isValidVMName(bad), bad)
        }
        for good in ["vitrine", "dev_1", "_svc"] { XCTAssertTrue(VMCreationJob.isValidUsername(good), good) }
        for bad in ["", "Leo", "1abc", "a;rm", "a b", "administrator", "guest", "root", String(repeating: "a", count: 33)] {
            XCTAssertFalse(VMCreationJob.isValidUsername(bad), bad)
        }
    }

    func testPasswordMeetsWindowsComplexity() {
        for _ in 0..<200 {
            let pw = VMCreationJob.generatePassword()
            XCTAssertEqual(pw.count, 20)
            XCTAssertTrue(pw.contains(where: \.isUppercase))
            XCTAssertTrue(pw.contains(where: \.isLowercase))
            XCTAssertTrue(pw.contains(where: \.isNumber))
            XCTAssertTrue(pw.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }, pw)
        }
        XCTAssertNotEqual(VMCreationJob.generatePassword(), VMCreationJob.generatePassword())
    }

    func testArgumentsNeverCarryThePassword() throws {
        var r = VMCreationJob.Request(name: "deb", kind: .debian)
        r.desktop = false
        r.cpus = 4
        r.memory = "4G"
        XCTAssertEqual(try VMCreationJob.arguments(for: r, windowsISO: nil),
                       ["create-linux", "deb", "--distro", "debian-13", "--desktop", "no", "--cpus", "4", "--memory", "4G",
                        "--user", "vitrine", "--password-stdin"])

        var w = VMCreationJob.Request(name: "win", kind: .windows)
        w.x64 = true
        let wargs = try VMCreationJob.arguments(for: w, windowsISO: URL(fileURLWithPath: "/tmp/Win11_x64.iso"))
        XCTAssertEqual(Array(wargs.prefix(6)), ["create-windows", "win", "--iso", "/tmp/Win11_x64.iso", "--arch", "x64"])

        let m = try VMCreationJob.arguments(for: VMCreationJob.Request(name: "mac", kind: .macOS), windowsISO: nil)
        XCTAssertEqual(Array(m.prefix(4)), ["create", "mac", "--ipsw", "latest"])

        for args in [wargs, m] {
            XCTAssertFalse(args.contains("--password"))
            XCTAssertEqual(args.last, "--password-stdin")
        }
    }

    func testArgumentsRejectUnsafeInput() {
        var r = VMCreationJob.Request(name: "deb", kind: .debian)
        r.username = "x; reboot"
        XCTAssertThrowsError(try VMCreationJob.arguments(for: r, windowsISO: nil))
        r = VMCreationJob.Request(name: "../escape", kind: .debian)
        XCTAssertThrowsError(try VMCreationJob.arguments(for: r, windowsISO: nil))
        r = VMCreationJob.Request(name: "deb", kind: .debian)
        r.memory = "8G --gui"
        XCTAssertThrowsError(try VMCreationJob.arguments(for: r, windowsISO: nil))
        r.memory = nil
        r.cpus = 0
        XCTAssertThrowsError(try VMCreationJob.arguments(for: r, windowsISO: nil))
        XCTAssertThrowsError(try VMCreationJob.arguments(for: VMCreationJob.Request(name: "w", kind: .windows), windowsISO: nil))
    }

    func testSummarizeKeepsLatestProgressAndTail() {
        let log = "download  10%\rdownload  55%\rdownload 100%\n\nextracting disk image…\n  \nbuilding cloud-init seed…\n"
        XCTAssertEqual(VMCreationJob.summarize(log, lines: 10), ["download 100%", "extracting disk image…", "building cloud-init seed…"])
        XCTAssertEqual(VMCreationJob.summarize(log, lines: 1), ["building cloud-init seed…"])
        XCTAssertEqual(VMCreationJob.exitCode(in: log), nil)
        XCTAssertEqual(VMCreationJob.exitCode(in: log + "\(VMCreationJob.exitMarker)0\n== starting deb\n"), 0)
        XCTAssertEqual(VMCreationJob.exitCode(in: "vitrinectl: bad --memory\n\(VMCreationJob.exitMarker)1\n"), 1)
    }

    func testStatusFromLogAndProcess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vcj-\(UUID().uuidString)")
        setenv("VITRINE_HOME", root.path, 1)
        defer { unsetenv("VITRINE_HOME"); try? FileManager.default.removeItem(at: root) }
        let job = VMCreationJob(name: "t")
        XCTAssertEqual(job.status(bundle: nil).state, .unknown)

        try job.reset()
        try job.begin(pid: getpid()) // a live process
        try Data("download 40%\n".utf8).write(to: job.logURL)
        XCTAssertEqual(job.status(bundle: nil).state, .creating)
        XCTAssertTrue(job.isActive)

        try Data("bad --disk\n\(VMCreationJob.exitMarker)1\n".utf8).write(to: job.logURL)
        XCTAssertEqual(job.status(bundle: nil).state, .failed)
        XCTAssertFalse(job.isActive)

        let bundleURL = VMLibrary.bundleURL(named: "t")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data("done\n\(VMCreationJob.exitMarker)0\n".utf8).write(to: job.logURL)
        XCTAssertEqual(job.status(bundle: VMBundle(url: bundleURL)).state, .created)

        // The process died without the marker (killed): failed, not "creating" forever.
        try job.begin(pid: 99_999_999)
        try Data("download 40%\n".utf8).write(to: job.logURL)
        XCTAssertEqual(job.status(bundle: nil).state, .failed)
    }

    func testCachedWindowsISOPicksArchitecture() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iso-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for f in ["Windows11_Client_arm64_en-us.iso", "virtio-win.iso", "OpenSSH-Win64.msi", "Win11_25H2_English_x64.iso"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(f).path, contents: Data())
        }
        XCTAssertEqual(VMCreationJob.cachedWindowsISO(x64: false, in: dir)?.lastPathComponent, "Windows11_Client_arm64_en-us.iso")
        XCTAssertEqual(VMCreationJob.cachedWindowsISO(x64: true, in: dir)?.lastPathComponent, "Win11_25H2_English_x64.iso")
    }
}
