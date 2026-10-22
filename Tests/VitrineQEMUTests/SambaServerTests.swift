import XCTest
@testable import VitrineQEMU
@testable import VitrineCore

final class SambaServerTests: XCTestCase {
    func testConfigEscapingAndValidation() throws {
        let dir = URL(fileURLWithPath: "/tmp/x")
        let conf = try SambaServer.config(directory: dir, username: "alice",
                                          shares: [.init(name: "My Files", path: "/Users/alice/My Files", readOnly: true)])
        XCTAssertTrue(conf.contains("[My Files]\npath = /Users/alice/My Files\nread only = yes\nvalid users = alice"))
        XCTAssertTrue(conf.contains("server signing = mandatory"))
        XCTAssertTrue(conf.contains("map to guest = never"))
        XCTAssertThrowsError(try SambaServer.config(directory: dir, username: "alice", shares: [.init(name: "a]b", path: "/", readOnly: false)]))
        XCTAssertThrowsError(try SambaServer.config(directory: dir, username: "alice", shares: [.init(name: "ok", path: "/a\nb", readOnly: false)]))
        XCTAssertFalse(SambaServer.isValidShareName(" lead"))
        XCTAssertTrue(SambaServer.isValidShareName("Projects 2026"))
        // The drag-and-drop share is Vitrine's own: users can't take its name, but it is served.
        XCTAssertFalse(SambaServer.isValidShareName("vitrinetransfer"))
        XCTAssertNoThrow(try SambaServer.config(directory: dir, username: "alice",
                                                shares: [.init(name: SambaServer.transferShare, path: "/t", readOnly: true)]))
        XCTAssertThrowsError(try SambaServer.config(directory: dir, username: "alice", shares: [.init(name: "p", path: "/a%U", readOnly: false)]))
    }

    func testCommandQuotesPathsForLibslirp() {
        XCTAssertEqual(SambaServer.quote("/a b/it's"), "'/a b/it'\\''s'")
    }

    /// Runs the generated configuration in a real smbd and logs in with smbclient: right password
    /// works (SMB3, signed), a wrong one and guest access don't.
    func testRealSmbdAcceptsOnlyTheGeneratedPassword() throws {
        guard let smbd = SambaServer.findSmbd() else { throw XCTSkip("Samba not installed") }
        let smbclient = smbd.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("bin/smbclient")
        guard FileManager.default.isExecutableFile(atPath: smbclient.path) else { throw XCTSkip("smbclient not installed") }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("smbtest-\(UUID().uuidString.prefix(8))")
        let shared = root.appendingPathComponent("shared dir")
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try "hi".write(to: shared.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        let server = try SambaServer(directory: root.appendingPathComponent("smb"),
                                     shares: [.init(name: "Work", path: shared.path, readOnly: false)])

        let port = Int.random(in: 40000..<50000)
        let conf = root.appendingPathComponent("smb/smb.conf").path
        let daemon = Process()
        daemon.executableURL = smbd
        daemon.arguments = ["-s", conf, "-F", "--no-process-group", "--option=smb ports=\(port)", "--option=interfaces=127.0.0.1",
                            "--option=bind interfaces only=yes"]
        let daemonOut = Pipe()
        daemon.standardInput = FileHandle.nullDevice // a socket on stdin would put smbd in inetd mode
        daemon.standardOutput = daemonOut
        daemon.standardError = daemonOut
        try daemon.run()
        defer { daemon.terminate(); daemon.waitUntilExit() }
        Thread.sleep(forTimeInterval: 1.5)
        guard daemon.isRunning else {
            let log = (try? String(contentsOfFile: root.appendingPathComponent("smb/smbd.log").path, encoding: .utf8)) ?? ""
            return XCTFail("smbd exited: \(String(decoding: daemonOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)) \(log.suffix(1500))")
        }

        func client(_ user: [String], _ command: String) throws -> (Int32, String) {
            let p = Process()
            p.executableURL = smbclient
            p.arguments = ["-s", conf, "//127.0.0.1/Work", "-p", "\(port)", "-m", "SMB3", "--client-protection=sign"] + user + ["-c", command]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            try p.run(); p.waitUntilExit()
            return (p.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        let ok = try client(["-U", "\(server.username)%\(server.password)"], "ls; mkdir fromguest")
        XCTAssertEqual(ok.0, 0, ok.1)
        XCTAssertTrue(ok.1.contains("hello.txt"), ok.1)
        XCTAssertTrue(fm.fileExists(atPath: shared.appendingPathComponent("fromguest").path), "share is writable")
        let wrong = try client(["-U", "\(server.username)%wrong"], "ls")
        XCTAssertNotEqual(wrong.0, 0)
        XCTAssertTrue(wrong.1.contains("LOGON_FAILURE"), wrong.1)
        let guest = try client(["-N"], "ls")
        XCTAssertNotEqual(guest.0, 0, guest.1)
    }
}
