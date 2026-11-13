import XCTest
@testable import VitrineCore

/// Guests that send an RFC 4361 client identifier (systemd-networkd) appear in bootpd's lease file
/// as "ff,<IAID>:<DUID>"; the MAC must still be found in DUID-LLT and DUID-LL identifiers.
final class GuestNetworkDUIDTests: XCTestCase {
    let leases = """
    {
    \tname=debian
    \tip_address=192.168.64.26
    \thw_address=ff,42:6b:b5:94:0:1:0:1:32:86:1b:e8:0:1c:42:6b:b5:94
    \tlease=0x6af36d79
    }
    {
    \tname=ll
    \tip_address=192.168.64.30
    \thw_address=ff,1:2:3:4:0:3:0:1:52:54:0:aa:bb:cc
    \tlease=0x6af36d79
    }
    {
    \tname=en
    \tip_address=192.168.64.31
    \thw_address=ff,1:2:3:4:0:2:0:0:ab:11:22:33:44:55:66:77
    \tlease=0x6af36d79
    }
    {
    \tname=plain
    \tip_address=192.168.64.25
    \thw_address=1,de:89:ca:6b:61:5d
    \tlease=0x6af36d79
    }
    """

    func testFindsMACsInClientIdentifiers() {
        XCTAssertEqual(GuestNetwork.ipAddress(forMAC: "00:1c:42:6b:b5:94", leases: leases), "192.168.64.26")
        XCTAssertEqual(GuestNetwork.ipAddress(forMAC: "52:54:00:aa:bb:cc", leases: leases), "192.168.64.30")
        XCTAssertEqual(GuestNetwork.ipAddress(forMAC: "de:89:ca:6b:61:5d", leases: leases), "192.168.64.25")
    }

    func testOtherIdentifiersMatchNothing() {
        XCTAssertNil(GuestNetwork.hardwareAddress(fromLeaseField: "ff,1:2:3:4:0:2:0:0:ab:11:22:33:44:55:66:77"))
        XCTAssertNil(GuestNetwork.hardwareAddress(fromLeaseField: "ff,1:2:3"))
        XCTAssertNil(GuestNetwork.hardwareAddress(fromLeaseField: "ff,1:2:3:4:0:1:0:1:zz"))
        XCTAssertNil(GuestNetwork.ipAddress(forMAC: "11:22:33:44:55:66", leases: leases))
    }
}
