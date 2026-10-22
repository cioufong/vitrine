import XCTest
@testable import VitrineCore

/// Frames shaped like the ones a guest sends, for `GuestNetwork.senderIPv4`.
enum GuestFrames {
    static let guest: [UInt8] = [0xd2, 0x91, 0x8d, 0x80, 0x1a, 0x95]
    static let other: [UInt8] = [0x02, 0x42, 0xac, 0x11, 0x00, 0x02]
    static let broadcast = [UInt8](repeating: 0xff, count: 6)

    static func ip(_ s: String) -> [UInt8] { s.split(separator: ".").map { UInt8($0)! } }

    static func arp(from mac: [UInt8], sender: String, senderMAC: [UInt8]? = nil) -> [UInt8] {
        // Built in steps: Swift 6.2 times out type-checking one long concatenation.
        var f = broadcast + mac
        f += [0x08, 0x06]
        f += [0, 1, 0x08, 0, 6, 4, 0, 1]
        f += senderMAC ?? mac
        f += ip(sender)
        f += [UInt8](repeating: 0, count: 6)
        f += ip("192.168.1.1")
        return f
    }

    static func ipv4(from mac: [UInt8], source: String) -> [UInt8] {
        var f = broadcast + mac
        f += [0x08, 0x00]
        f += [0x45, 0, 0, 20, 0, 0, 0, 0, 64, 17, 0, 0]
        f += ip(source)
        f += ip("192.168.1.1")
        return f
    }
}

final class GuestFrameAddressTests: XCTestCase {
    private func sender(_ frame: [UInt8], mac: [UInt8] = GuestFrames.guest) -> String? {
        frame.withUnsafeBytes { GuestNetwork.senderIPv4(ofFrame: $0, from: mac) }.map(IPv4Subnet.format)
    }

    func testSenderAddressFromARPAndIPv4() {
        XCTAssertEqual(sender(GuestFrames.arp(from: GuestFrames.guest, sender: "192.168.1.23")), "192.168.1.23")
        XCTAssertEqual(sender(GuestFrames.ipv4(from: GuestFrames.guest, source: "192.168.1.23")), "192.168.1.23")
    }

    func testFramesThatSayNothing() {
        let g = GuestFrames.guest
        XCTAssertNil(sender(GuestFrames.ipv4(from: GuestFrames.other, source: "172.17.0.2")), "a container's MAC")
        XCTAssertNil(sender(GuestFrames.arp(from: g, sender: "10.0.0.9", senderMAC: GuestFrames.other)),
                     "ARP for another adapter, relayed by the guest")
        XCTAssertNil(sender(GuestFrames.arp(from: g, sender: "0.0.0.0")), "ARP probe")
        XCTAssertNil(sender(GuestFrames.ipv4(from: g, source: "0.0.0.0")), "DHCP request")
        let arp = GuestFrames.arp(from: g, sender: "192.168.1.23"), ipv4 = GuestFrames.ipv4(from: g, source: "192.168.1.23")
        for n in [0, 6, 13, 14, 30, 41] { XCTAssertNil(sender(Array(arp.prefix(n))), "ARP cut at \(n)") }
        for n in [14, 25, 33] { XCTAssertNil(sender(Array(ipv4.prefix(n))), "IPv4 cut at \(n)") }
        var v6 = ipv4; v6[14] = 0x60
        XCTAssertNil(sender(v6), "not an IPv4 header")
        var shortHeader = ipv4; shortHeader[14] = 0x44
        XCTAssertNil(sender(shortHeader), "IHL below 5")
        var vlan = ipv4; vlan[12] = 0x81; vlan[13] = 0x00
        XCTAssertNil(sender(vlan), "802.1Q tagged frames are not parsed")
        var ipv6ARP = arp; ipv6ARP[16] = 0x86; ipv6ARP[17] = 0xdd
        XCTAssertNil(sender(ipv6ARP), "ARP for another protocol")
        XCTAssertNil(sender(arp, mac: []), "no MAC to match")
    }

    func testMACBytes() {
        XCTAssertEqual(GuestNetwork.macBytes("d2:91:8d:80:1a:95"), GuestFrames.guest)
        XCTAssertEqual(GuestNetwork.macBytes("2:0:0:0:0:a"), [2, 0, 0, 0, 0, 10])
        for bad in ["", "d2:91:8d:80:1a", "d2:91:8d:80:1a:95:00", "d2:91:8d:80:1a:zz", "d2:91:8d:80:1a:195", "d2::8d:80:1a:95"] {
            XCTAssertNil(GuestNetwork.macBytes(bad), bad)
        }
    }
}
