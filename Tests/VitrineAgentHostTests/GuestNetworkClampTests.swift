import XCTest
@testable import VitrineAgentProtocol

/// An interface with more addresses than the host's limit (a Docker host, a guest with many IPv6
/// privacy addresses) must not fail the message: the channel would close and every reconnect would
/// fail the same way while those addresses exist. Older agents send everything, so the host clamps.
final class GuestNetworkClampTests: XCTestCase {
    private func payload(ipv4 count4: Int, ipv6 count6: Int) throws -> Data {
        let info: [String: Any] = ["interfaces": [[
            "name": "eth0", "mac": "52:54:00:12:34:56",
            "ipv4": (0..<count4).map { "10.0.\($0 / 256).\($0 % 256)" },
            "ipv6": (0..<count6).map { "fd00::\(String($0, radix: 16))" },
        ]]]
        return try JSONSerialization.data(withJSONObject: info)
    }

    func testFortyAddressesAreClampedNotRejected() throws {
        let message = try AgentCodec.decode(type: MessageType.guestNetwork.rawValue, payload: payload(ipv4: 40, ipv6: 40))
        guard case .guestNetwork(let info) = message else { return XCTFail("not guest network info") }
        let eth0 = try XCTUnwrap(info.interfaces.first)
        XCTAssertEqual(eth0.ipv4, (0..<GuestNetworkInfo.maxAddressesPerFamily).map { "10.0.0.\($0)" }, "first addresses kept, in order")
        XCTAssertEqual(eth0.ipv6, (0..<GuestNetworkInfo.maxAddressesPerFamily).map { "fd00::\(String($0, radix: 16))" })
        XCTAssertTrue(info.isSane)
    }

    func testTooManyInterfacesAreClamped() throws {
        let one: [String: Any] = ["name": "veth", "mac": "52:54:00:12:34:56", "ipv4": ["10.0.0.1"], "ipv6": []]
        let data = try JSONSerialization.data(withJSONObject: ["interfaces": Array(repeating: one, count: 80)])
        guard case .guestNetwork(let info) = try AgentCodec.decode(type: MessageType.guestNetwork.rawValue, payload: data)
        else { return XCTFail("not guest network info") }
        XCTAssertEqual(info.interfaces.count, GuestNetworkInfo.maxInterfaces)
    }

    func testOversizedStringsAreStillRejected() throws {
        let bad: [String: Any] = ["interfaces": [["name": String(repeating: "x", count: 100), "mac": "52:54:00:12:34:56",
                                                  "ipv4": ["10.0.0.1"], "ipv6": []]]]
        XCTAssertThrowsError(try AgentCodec.decode(type: MessageType.guestNetwork.rawValue,
                                                   payload: JSONSerialization.data(withJSONObject: bad)))
    }
}
