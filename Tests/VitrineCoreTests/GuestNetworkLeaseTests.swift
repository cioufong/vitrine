import XCTest
@testable import VitrineCore

final class GuestNetworkLeaseTests: XCTestCase {
    func testCloneCannotResolveTheSourceHostname() {
        XCTAssertEqual(GuestNetwork.candidates(mac: "be:47:a9:b7:36:99", hostname: "debian-test",
                                              leases: leases, arp: []), [])
    }

    // A guest that moved to a DUID-based DHCP client: its MAC lease is days older than the one
    // recorded under its host name (seen on debian-test, 2026-10-20).
    let leases = """
    {
    \tname=debian-test
    \tip_address=192.168.64.4
    \thw_address=ff,f1:f5:dd:7f:0:2:0:0:ab:11:f5:42:a1:6e:1c:f6:b3:f8
    \tlease=0x6ad71bee
    }
    {
    \tname=debian-test
    \tip_address=192.168.64.5
    \thw_address=1,be:47:a9:b7:36:2c
    \tlease=0x6accb2e8
    }
    """

    func testHostnameLeaseWithoutMatchingMACIsIgnored() {
        XCTAssertEqual(GuestNetwork.candidates(mac: "be:47:a9:b7:36:2c", hostname: "debian-test", leases: leases, arp: []),
                       ["192.168.64.5"])
    }

    func testNewerMACLeaseComesFirst() {
        // Both leases carry the host name, so the newest by name is the MAC lease too.
        let swapped = leases.replacingOccurrences(of: "0x6accb2e8", with: "0x6ae00000")
        XCTAssertEqual(GuestNetwork.candidates(mac: "be:47:a9:b7:36:2c", hostname: "debian-test", leases: swapped, arp: []),
                       ["192.168.64.5"])
    }

    func testARPRemainsAvailableAfterTheMACLease() {
        XCTAssertEqual(GuestNetwork.candidates(mac: "be:47:a9:b7:36:2c", hostname: "debian-test", leases: leases, arp: ["192.168.64.9"]),
                       ["192.168.64.5", "192.168.64.9"])
    }

    func testARPOwnerOfAnAddress() {
        let arp = """
        ? (192.168.64.4) at be:47:a9:b7:36:2c on bridge100 ifscope [bridge]
        ? (192.168.64.9) at (incomplete) on bridge100 ifscope [bridge]
        """
        XCTAssertEqual(GuestNetwork.arpMAC(forIP: "192.168.64.4", arpOutput: arp), "be:47:a9:b7:36:2c")
        XCTAssertNil(GuestNetwork.arpMAC(forIP: "192.168.64.9", arpOutput: arp))
        XCTAssertNil(GuestNetwork.arpMAC(forIP: "192.168.64.40", arpOutput: arp))
    }
}
