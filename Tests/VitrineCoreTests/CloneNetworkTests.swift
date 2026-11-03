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

    /// A suspended guest's disk is only consistent together with its saved memory (dirty page
    /// cache, journal not yet flushed). A clone gets the disk alone, so it would boot as after a
    /// power cut; refuse instead, before creating anything.
    func testCloneRefusesASuspendedVM() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-clone-saved-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = VMConfig(name: "Paused", guestOS: .linux)
        config.disks = [.init(path: "disk.img")]
        let dest = root.appendingPathComponent("b.vitrinevm")
        for state in ["state.vzvmsave", "state.qemusave"] {
            let source = try VMBundle.create(at: root.appendingPathComponent("a-\(state).vitrinevm"), config: config)
            try Data("disk".utf8).write(to: source.resolve("disk.img"))
            try Data("memory".utf8).write(to: source.url.appendingPathComponent(state))
            XCTAssertThrowsError(try VMCloner.clone(source, to: dest, newName: "Copy"), state) { error in
                XCTAssertTrue("\(error.localizedDescription)".contains("suspended"), "\(error)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path), "nothing created for \(state)")
        }
    }
}
