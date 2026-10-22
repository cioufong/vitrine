import XCTest
@testable import VitrineVZ
@testable import VitrineCore
@testable import VitrineQEMU
import VitrineAgentProtocol

final class WindowsShareSafetyTests: XCTestCase {
    func testDriveLettersStayWithTheirFolders() {
        var c = VMConfig(name: "w", guestOS: .windows, cpuCount: 2, memoryMiB: 4096)
        c.shares = [.init(hostPath: "/a", name: "A"), .init(hostPath: "/b", name: "B")]
        XCTAssertTrue(c.assignDriveLetters())
        XCTAssertEqual(c.shares.map(\.driveLetter), ["Z", "Y"])
        // Removing the first folder doesn't move the second; a new one takes the free letter.
        c.shares.removeFirst()
        c.shares.append(.init(hostPath: "/c", name: "C"))
        c.assignDriveLetters()
        XCTAssertEqual(c.shares.map(\.driveLetter), ["Y", "Z"])
        XCTAssertFalse(c.assignDriveLetters())

        let mapped = VirtualMachineController.driveMappings([
            .init(name: "B", path: "/b", readOnly: false, letter: "Y"),
            .init(name: "New", path: "/n", readOnly: false),
            .init(name: SambaServer.transferShare, path: "/t", readOnly: true),
        ])
        XCTAssertEqual(mapped.map(\.letter), ["Y", "Z", nil])
    }

    func testSambaRejectsPathsItWouldMisread() {
        XCTAssertTrue(SambaServer.isServablePath("/Users/alice/Projects"))
        XCTAssertFalse(SambaServer.isServablePath("/tmp/folder "))
        XCTAssertFalse(SambaServer.isServablePath(" /tmp/folder"))
        XCTAssertFalse(SambaServer.isServablePath("/tmp/folder\\"))
        XCTAssertFalse(SambaServer.isServablePath("/tmp/100%"))
        XCTAssertFalse(SambaServer.isValidShareName("Global"))
        XCTAssertFalse(SambaServer.isValidShareName("print$"))
        XCTAssertTrue(SambaServer.isValidShareName("Projects"))
    }

    /// The reload signal (SIGHUP) must reach the instance's smbd processes and never QEMU, whose
    /// command line carries the same paths inside its guestfwd option (SIGHUP would stop the VM).
    func testSambaReloadPatternMatchesOnlySmbd() throws {
        let smbd = "/opt/homebrew/sbin/samba-dot-org-smbd", conf = "/var/T/vitrine-x/smb/smb.conf"
        let regex = try NSRegularExpression(pattern: SambaServer.reloadPattern(smbd: smbd, conf: conf))
        func matches(_ s: String) -> Bool { regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        XCTAssertTrue(matches("\(smbd) -s \(conf)"))
        XCTAssertFalse(matches("/opt/homebrew/bin/qemu-system-aarch64 -netdev user,id=net0,guestfwd=tcp:10.0.2.4:445-cmd:'\(smbd)' -s '\(conf)'"))
        XCTAssertFalse(matches("\(smbd) -s /var/T/vitrine-y/smb/smb.conf")) // another VM's instance

        // pkill evaluates it as a POSIX extended regex (Darwin regcomp), not ICU: check that too.
        var re = regex_t()
        guard regcomp(&re, SambaServer.reloadPattern(smbd: smbd, conf: conf), REG_EXTENDED | REG_NOSUB) == 0 else {
            return XCTFail("the reload pattern isn't a valid POSIX extended regex")
        }
        defer { regfree(&re) }
        func ere(_ s: String) -> Bool { regexec(&re, s, 0, nil, 0) == 0 }
        XCTAssertTrue(ere("\(smbd) -s \(conf)"))
        XCTAssertFalse(ere("qemu ... guestfwd=tcp:10.0.2.4:445-cmd:'\(smbd)' -s '\(conf)'"))
        XCTAssertFalse(ere("\(smbd) -s /var/T/vitrine-x/smb/smbXconf"))
    }

    func testGuestStringsCountTowardsReceiveLimit() {
        let huge = String(repeating: "x", count: 1 << 20)
        let catalog = AgentMessage.appCatalog(AppCatalog(apps: [AppCatalog.App(id: "1", name: huge)]))
        XCTAssertGreaterThan(catalog.approximateSize, 1 << 20)
        let icon = AgentMessage.appIcon(AppIcon(key: huge, png: Data()))
        XCTAssertGreaterThan(icon.approximateSize, 1 << 20)
    }
}
