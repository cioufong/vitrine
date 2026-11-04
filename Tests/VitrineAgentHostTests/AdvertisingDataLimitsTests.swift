import XCTest
@testable import VitrineAgentHost

/// CoreBluetooth merges the advertisement and scan response, and Bluetooth 5 extended advertising
/// carries up to 1650 bytes, so a nearby device can hand over fields far longer than an AD structure
/// (255 bytes) or a legacy payload (31 bytes) can hold.
final class AdvertisingDataLimitsTests: XCTestCase {
    func testOversizedFieldsDontTrapAndPayloadsStayValid() {
        let longUUID = BTUUID(le: Data((0..<16).map { UInt8($0) }))!
        let ad = BLEAdvertisement(
            localName: "Sensor",
            serviceUUIDs: (0..<200).map { BTUUID(UInt16(0x1800 + $0)) } + [longUUID, BTUUID(le: Data(repeating: 7, count: 16))!],
            manufacturerData: Data(repeating: 0xAB, count: 600),
            serviceData: [BTUUID(0xFEAA): Data(repeating: 1, count: 300)],
            txPower: -8)
        let (adv, rsp) = AdvertisingData.build(ad)
        for payload in [adv, rsp] {
            XCTAssertLessThanOrEqual(payload.count, AdvertisingData.maxLength)
            XCTAssertNotNil(structures(payload), "malformed AD structures: \(payload)")
        }
        let all = (structures(adv) ?? []) + (structures(rsp) ?? [])
        // Too many 16-bit UUIDs for one structure: as many as fit, marked incomplete.
        let uuids16 = all.first { $0.first == 0x02 }
        XCTAssertNotNil(uuids16)
        XCTAssertEqual(uuids16.map { ($0.count - 1) % 2 }, 0)
        XCTAssertNil(all.first { $0.first == 0x03 }, "a complete list claimed for a cut one")
        // Fields that can't fit at all are left out rather than cut.
        XCTAssertNil(all.first { $0.first == 0xFF })
        XCTAssertNil(all.first { $0.first == 0x16 })
        XCTAssertTrue(all.contains { $0.first == 0x0A })  // Tx power still there
    }

    func testAllUUIDsThatFitStayComplete() {
        let (adv, _) = AdvertisingData.build(BLEAdvertisement(serviceUUIDs: [BTUUID(0x180D), BTUUID(0x180F)], isConnectable: false))
        XCTAssertEqual(adv, [5, 0x03, 0x0D, 0x18, 0x0F, 0x18])
    }

    /// Splits a payload into AD structures (type byte + data), nil when the lengths don't add up.
    private func structures(_ p: [UInt8]) -> [[UInt8]]? {
        var out: [[UInt8]] = [], i = 0
        while i < p.count {
            let len = Int(p[i])
            guard len > 0, i + 1 + len <= p.count else { return nil }
            out.append(Array(p[(i + 1)...(i + len)]))
            i += 1 + len
        }
        return out
    }
}
