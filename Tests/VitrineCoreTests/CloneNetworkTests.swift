import Foundation
import XCTest
@testable import VitrineCore

/// A cloned Linux disk keeps announcing its original host name to DHCP, and DUID-based clients
/// (systemd-networkd) leave no MAC in the lease: the clone must look the guest up by that name.
final class CloneNetworkTests: XCTestCase {
    func testCloneKeepsTheGuestsDHCPHostName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-clone-net-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = VMConfig(name: "Debian Box", guestOS: .linux)
        config.disks = [.init(path: "disk.img")]
        let source = try VMBundle.create(at: root.appendingPathComponent("a.vitrinevm"), config: config)
        try Data("disk".utf8).write(to: source.resolve("disk.img"))

        let clone = try VMCloner.clone(source, to: root.appendingPathComponent("b.vitrinevm"), newName: "Copy")
        let cloned = try clone.loadConfig()
        XCTAssertEqual(cloned.dhcpHostname, "debian-box")
        XCTAssertNotEqual(cloned.network.macAddress, config.network.macAddress)

        var created = config
        created.guestHostname = "set-by-cloud-init"
        XCTAssertEqual(created.dhcpHostname, "set-by-cloud-init")
        created.guestOS = .windows
        XCTAssertNil(created.dhcpHostname)
    }
}
