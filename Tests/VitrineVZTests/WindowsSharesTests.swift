import XCTest
@testable import VitrineVZ
@testable import VitrineQEMU
@testable import VitrineCore

final class WindowsSharesTests: XCTestCase {
    func testDriveLettersFromZDownTransferShareLetterless() {
        let shares: [SambaServer.Share] = [.init(name: "A", path: "/a", readOnly: false), .init(name: "B", path: "/b", readOnly: true),
                                           .init(name: SambaServer.transferShare, path: "/t", readOnly: true)]
        let m = VirtualMachineController.driveMappings(shares)
        XCTAssertEqual(m.map(\.letter), ["Z", "Y", nil])
        XCTAssertEqual(m.map(\.readOnly), [false, true, true])
    }

    func testSMBSharesSkipInvalidNamesAndAddTransfer() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("b-\(UUID().uuidString).vitrinevm")
        let bundle = VMBundle(url: dir)
        var c = VMConfig(name: "w", guestOS: .windows)
        c.shares = [.init(hostPath: "~/Docs", name: "Docs"), .init(hostPath: "/x", name: "bad:name"),
                    .init(hostPath: "/y", name: "vitrinetransfer")]
        let s = QEMUMachine.smbShares(config: c, bundle: bundle)
        XCTAssertEqual(s.map(\.name), ["Docs", SambaServer.transferShare])
        XCTAssertEqual(s.first?.path, (("~/Docs") as NSString).expandingTildeInPath)
        XCTAssertEqual(s.last?.path, bundle.transferDirectory.path)
    }

    func testWindowsConfigRejectsSMBUnsafeNames() {
        var c = VMConfig(name: "w", guestOS: .windows)
        c.disks = [.init(path: "disk.img")]
        c.shares = [.init(hostPath: "/tmp", name: "a;b")]
        let bundle = VMBundle(url: FileManager.default.temporaryDirectory.appendingPathComponent("v.vitrinevm"))
        // A large host, so only the share names can fail (CI runners can have 3 CPUs).
        let big = (cpus: 64, mib: UInt64(1 << 20))
        XCTAssertThrowsError(try c.validate(bundle: bundle, hostCPUs: big.cpus, hostMemoryMiB: big.mib)) { XCTAssertTrue($0.localizedDescription.contains("can't be used with Windows"), $0.localizedDescription) }
        c.shares = [.init(hostPath: "/tmp", name: "Docs"), .init(hostPath: "/var", name: "docs")]
        XCTAssertThrowsError(try c.validate(bundle: bundle, hostCPUs: big.cpus, hostMemoryMiB: big.mib)) { XCTAssertTrue($0.localizedDescription.contains("duplicate"), $0.localizedDescription) }
    }
}
