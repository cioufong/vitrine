import XCTest
@testable import VitrineQEMU
@testable import VitrineCore

final class UnattendedX64Tests: XCTestCase {
    func testSetupInstallsOpenSSHFromTheSeedWhenPresent() {
        let s = WindowsUnattend.setupScript
        XCTAssertTrue(s.contains(#"if not exist "%SEED%\vitrine\openssh.msi" goto ssh_fod"#))
        XCTAssertTrue(s.contains("msiexec /i"))
        XCTAssertTrue(s.contains("if %errorlevel% equ 3010 goto ssh_start")) // success with a reboot pending
        XCTAssertTrue(s.contains("Add-WindowsCapability")) // fallback when the MSI isn't there or fails
        // msiexec fails with 1619 on a package path containing "..": the seed path is made absolute.
        XCTAssertTrue(s.contains(#"for %%I in ("%~dp0..") do set "SEED=%%~fI""#))
        XCTAssertFalse(s.contains("set SEED=%~dp0.."))
    }

    /// Emulated x64's user OOBE trips Windows' OOBE watchdog, which reboots into a "connect to a
    /// network for an update" screen; the x64 answer file skips OOBE's screens altogether.
    func testOnlyX64SkipsOOBE() throws {
        var o = WindowsUnattend.Options(architecture: .x86_64, computerName: "X", fullName: "U", username: "u", password: "p")
        XCTAssertFalse(WindowsUnattend.xml(o).contains("SkipMachineOOBE"))
        o.skipOOBE = true
        let xml = WindowsUnattend.xml(o)
        XCTAssertTrue(xml.contains("<SkipMachineOOBE>true</SkipMachineOOBE>"))
        XCTAssertTrue(xml.contains("<SkipUserOOBE>true</SkipUserOOBE>"))
        _ = try XMLDocument(xmlString: xml) // still well-formed
    }

    /// virtio-win drivers are installed with administrator rights: a pinned release, verified.
    func testVirtioWinIsPinnedAndVerified() throws {
        XCTAssertTrue(WindowsCreator.virtioWinURL.absoluteString.contains("archive-virtio/virtio-win-\(WindowsCreator.virtioWinVersion)-1/"))
        XCTAssertEqual(WindowsCreator.virtioWinSHA256.count, 64)
        let cached = VMLibrary.cacheDirectory.appendingPathComponent("windows/virtio-win.iso")
        guard FileManager.default.fileExists(atPath: cached.path) else { throw XCTSkip("virtio-win.iso not cached") }
        XCTAssertEqual(try WindowsCreator.sha256(of: cached), WindowsCreator.virtioWinSHA256)
    }

    func testOpenSSHMSIsArePinned() {
        XCTAssertEqual(WindowsCreator.openSSHMSI(.x86_64).name, "OpenSSH-Win64-v10.0.0.0.msi")
        XCTAssertEqual(WindowsCreator.openSSHMSI(.aarch64).name, "OpenSSH-ARM64-v10.0.0.0.msi")
        XCTAssertEqual(WindowsCreator.openSSHMSI(.x86_64).sha256.count, 64)
    }

    func testOnlyEmulatedX64SetupRunsOffline() {
        var c = VMConfig(name: "x", guestOS: .windows)
        c.backend = .qemu
        c.architecture = .x86_64
        c.installMedia = "/w.iso"
        c.extraMedia = ["seed.iso"]
        XCTAssertFalse(WindowsSetup(c).runsOffline) // seed without OpenSSH: Setup needs Windows Update
        c.windowsSetupOffline = true
        XCTAssertTrue(WindowsSetup(c).runsOffline)
        c.windowsSetupAgentSeen = true // setup reached the agent: done, media just not ejected yet
        XCTAssertFalse(WindowsSetup(c).runsOffline)
        c.windowsSetupAgentSeen = nil
        c.installMedia = nil // setup finished: back online
        XCTAssertFalse(WindowsSetup(c).runsOffline)
        c.installMedia = "/w.iso"
        c.architecture = .aarch64 // Windows on Arm installs fast enough online
        XCTAssertFalse(WindowsSetup(c).runsOffline)
        c.architecture = .x86_64
        c.extraMedia = nil // interactive setup (no seed): the user may want the network
        XCTAssertFalse(WindowsSetup(c).runsOffline)
    }
}
