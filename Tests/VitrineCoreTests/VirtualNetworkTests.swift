import XCTest
@testable import VitrineCore

final class VirtualNetworkTests: XCTestCase {
    func testSubnets() {
        let s = IPv4Subnet(cidr: "192.168.100.7/24")!
        XCTAssertEqual(s.cidr, "192.168.100.0/24", "host bits are cleared")
        XCTAssertEqual(s.hostAddress, "192.168.100.1")
        XCTAssertEqual(IPv4Subnet.format(s.assignableRange.lowerBound), "192.168.100.2")
        XCTAssertEqual(IPv4Subnet.format(s.assignableRange.upperBound), "192.168.100.254")
        XCTAssertTrue(s.contains("192.168.100.200"))
        XCTAssertFalse(s.contains("192.168.101.2"))
        XCTAssertNotNil(IPv4Subnet(cidr: "10.20.0.0/16"))
        XCTAssertNotNil(IPv4Subnet(cidr: "172.31.5.0/29"))
        XCTAssertNil(IPv4Subnet(cidr: "8.8.8.0/24"), "public range")
        XCTAssertNil(IPv4Subnet(cidr: "172.32.0.0/24"), "outside 172.16/12")
        XCTAssertNil(IPv4Subnet(cidr: "192.168.1.0/30"), "too small")
        XCTAssertNil(IPv4Subnet(cidr: "10.0.0.0/8"), "too large")
        XCTAssertNil(IPv4Subnet(cidr: "192.168.1.0"))
        XCTAssertNil(IPv4Subnet.parse("1.2.3"))
        XCTAssertNil(IPv4Subnet.parse("1.2.3.256"))
        XCTAssertNil(IPv4Subnet.parse("1.2..3"))
    }

    func testDefinitions() {
        XCTAssertNil(VirtualNetwork(name: "Lab 1_a-b").problem)
        XCTAssertNotNil(VirtualNetwork(name: "").problem)
        XCTAssertNotNil(VirtualNetwork(name: " lab").problem)
        XCTAssertNotNil(VirtualNetwork(name: "a/b").problem)
        XCTAssertNotNil(VirtualNetwork(name: String(repeating: "x", count: 33)).problem)
        XCTAssertNotNil(VirtualNetwork(name: "lab", subnet: "1.2.3.0/24").problem)
        let old = try! JSONDecoder().decode(VirtualNetwork.self, from: Data(#"{"name":"lab"}"#.utf8))
        XCTAssertEqual(old, VirtualNetwork(name: "lab", kind: .shared, subnet: nil, dhcp: true))
    }

    func testSavingRejectsDuplicatesAndOverlaps() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("vnet-\(UUID().uuidString)")
        setenv("VITRINE_HOME", home.path, 1)
        defer { unsetenv("VITRINE_HOME"); try? FileManager.default.removeItem(at: home) }
        XCTAssertThrowsError(try VirtualNetworks.save([.init(name: "lab"), .init(name: "LAB")]))
        XCTAssertThrowsError(try VirtualNetworks.save([.init(name: "a", subnet: "10.1.0.0/16"), .init(name: "b", subnet: "10.1.5.0/24")]))
        try VirtualNetworks.save([.init(name: "a", subnet: "10.1.0.0/24"), .init(name: "b", kind: .hostOnly, subnet: "10.1.1.0/24", dhcp: false)])
        XCTAssertEqual(VirtualNetworks.named("b")?.kind, .hostOnly)
        XCTAssertEqual(VirtualNetworks.named("b")?.dhcp, false)
    }

    func testOlderNetworkConfigsDecode() throws {
        let n = try JSONDecoder().decode(VMConfig.NetworkConfig.self, from: Data(#"{"mode":"hostOnly","macAddress":"02:00:00:00:00:01"}"#.utf8))
        XCTAssertEqual(n.mode, .hostOnly)
        XCTAssertNil(n.networkName)
        XCTAssertNil(n.bridgeInterface)
        XCTAssertNil(n.fixedIPv4)
    }

    func testReportedGuestIPNeedsTheRunningProcess() throws {
        let bundle = VMBundle(url: FileManager.default.temporaryDirectory.appendingPathComponent("ip-\(UUID().uuidString).vitrinevm"))
        try FileManager.default.createDirectory(at: bundle.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle.url); bundle.recordGuestIP(nil) }
        var c = VMConfig(name: "x", guestOS: .linux, cpuCount: 1, memoryMiB: 1024)
        bundle.recordGuestIP("192.168.120.9")
        XCTAssertNil(bundle.reportedGuestIP(c), "no process holds the VM's run lock")
        try bundle.acquireRunLock()
        defer { bundle.releaseRunLock() }
        XCTAssertEqual(bundle.reportedGuestIP(c), "192.168.120.9")
        XCTAssertEqual(bundle.guestIPAddress(c), "192.168.120.9")
        bundle.recordGuestIP("127.0.0.1")
        XCTAssertNil(bundle.reportedGuestIP(c), "a report pointing back at the Mac is ignored")
        bundle.recordGuestIP(nil)
        c.network.mode = .network
        c.network.fixedIPv4 = "192.168.120.50"
        XCTAssertEqual(bundle.guestIPAddress(c), "192.168.120.50", "the fixed address when the agent hasn't reported")
    }

    func testPlausibleGuestAddresses() {
        let mac = IPv4Subnet.parse("192.168.1.10")!
        let plausible = { (ip: String, ranges: [ClosedRange<UInt32>]?) in
            GuestNetwork.isPlausibleGuestAddress(ip, within: ranges, hostAddresses: [mac])
        }
        for ip in ["127.0.0.1", "127.8.9.1", "0.0.0.0", "0.1.2.3", "169.254.10.20", "224.0.0.251", "239.1.1.1",
                   "255.255.255.255", "240.0.0.1", "192.168.1.10", "::1", "fe80::1", "localhost", "192.168.1"] {
            XCTAssertFalse(plausible(ip, nil), ip)
        }
        XCTAssertTrue(plausible("192.168.64.5", nil), "no known subnet: any other unicast address")
        XCTAssertTrue(plausible("10.0.2.15", nil))
        let lab = IPv4Subnet(cidr: "192.168.120.0/24")!.assignableRange
        XCTAssertTrue(plausible("192.168.120.9", [lab]))
        for ip in ["192.168.121.9", "192.168.120.0", "192.168.120.1", "192.168.120.255"] {
            XCTAssertFalse(plausible(ip, [lab]), "\(ip) is not a guest address on 192.168.120.0/24")
        }
    }

    func testGuestRangesFromTheNetwork() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("vnet-\(UUID().uuidString)")
        setenv("VITRINE_HOME", home.path, 1)
        defer { unsetenv("VITRINE_HOME"); try? FileManager.default.removeItem(at: home) }
        try VirtualNetworks.save([.init(name: "lab", subnet: "192.168.120.0/24"), .init(name: "auto")])
        let en0 = GuestNetwork.HostAddress(interface: "en0", address: IPv4Subnet.parse("192.168.1.10")!,
                                           mask: IPv4Subnet.parse("255.255.255.0")!)
        var c = VMConfig(name: "x", guestOS: .linux, cpuCount: 1, memoryMiB: 1024)
        XCTAssertNil(GuestNetwork.guestRanges(c, host: [en0]), "NAT: macOS picks the subnet")
        c.network.mode = .network
        c.network.networkName = "lab"
        XCTAssertEqual(GuestNetwork.guestRanges(c, host: [en0]), [IPv4Subnet(cidr: "192.168.120.0/24")!.assignableRange])
        c.network.networkName = "auto"
        XCTAssertNil(GuestNetwork.guestRanges(c, host: [en0]))
        c.network.mode = .bridged
        c.network.bridgeInterface = "en0"
        XCTAssertEqual(GuestNetwork.guestRanges(c, host: [en0]), [IPv4Subnet.parse("192.168.1.1")!...IPv4Subnet.parse("192.168.1.254")!])
        c.network.bridgeInterface = "en1"
        XCTAssertNil(GuestNetwork.guestRanges(c, host: [en0]), "no address on the bridged interface")
    }
}
