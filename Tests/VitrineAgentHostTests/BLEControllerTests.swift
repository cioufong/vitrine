import XCTest
@testable import VitrineAgentHost

private final class FakeRadio: BLERadio {
    weak var delegate: BLERadioDelegate?
    var scans: [Bool] = [], stops = 0, connects: [UUID] = [], disconnects: [UUID] = []
    var values: [GATTTarget: Data] = [:]
    var writes: [(GATTTarget, Data, Bool)] = []
    var notify: [(Int, Bool)] = []

    func startScan(allowDuplicates: Bool) { scans.append(allowDuplicates) }
    func stopScan() { stops += 1 }
    func connect(_ peer: UUID) { connects.append(peer) }
    func disconnect(_ peer: UUID) { disconnects.append(peer) }
    func read(_ peer: UUID, _ target: GATTTarget, completion: @escaping (Result<Data, ATTError>) -> Void) {
        completion(values[target].map { .success($0) } ?? .failure(.readNotPermitted))
    }
    func write(_ peer: UUID, _ target: GATTTarget, value: Data, withResponse: Bool,
               completion: @escaping (Result<Void, ATTError>) -> Void) {
        writes.append((target, value, withResponse))
        completion(.success(()))
    }
    func setNotify(_ peer: UUID, characteristic: Int, enabled: Bool, completion: @escaping (Result<Void, ATTError>) -> Void) {
        notify.append((characteristic, enabled))
        completion(.success(()))
    }
    func stop() {}
}

final class BLEControllerTests: XCTestCase {
    private var radio: FakeRadio!
    private var controller: BLEController!
    private var out: [[UInt8]] = []
    private let peer = UUID(uuidString: "12345678-9ABC-DEF0-1122-334455667788")!
    private let heartRate = BTUUID(0x180D), measurement = BTUUID(0x2A37), location = BTUUID(0x2A38)

    override func setUp() {
        radio = FakeRadio()
        out = []
        controller = BLEController(address: [1, 2, 3, 4, 5, 6], radio: radio) { [unowned self] in self.out.append([UInt8]($0)) }
    }

    private func cmd(_ opcode: UInt16, _ params: [UInt8] = []) {
        controller.receive(Data([0x01, UInt8(opcode & 0xFF), UInt8(opcode >> 8), UInt8(params.count)] + params))
    }

    /// The return parameters of the Command Complete for `opcode` among the events sent.
    private func completed(_ opcode: UInt16) -> [UInt8]? {
        out.last { $0.count >= 6 && $0[0] == 0x04 && $0[1] == 0x0E && $0.u16(4) == opcode }.map { Array($0[6...]) }
    }

    private func leEvents(_ sub: UInt8) -> [[UInt8]] {
        out.filter { $0.count > 3 && $0[0] == 0x04 && $0[1] == 0x3E && $0[3] == sub }.map { Array($0[4...]) }
    }

    /// ATT PDUs sent on `handle` (each in one ACL packet: they're all well under 251 bytes).
    private func att(_ handle: UInt16) -> [[UInt8]] {
        out.filter { $0[0] == 0x02 && $0.u16(1) & 0x0FFF == handle && $0.u16(7) == 4 }.map { Array($0[9...]) }
    }

    private func sendATT(_ handle: UInt16, _ pdu: [UInt8]) {
        var p: [UInt8] = [0x02]
        p.put16(handle); p.put16(UInt16(pdu.count + 4)); p.put16(UInt16(pdu.count)); p.put16(4)
        controller.receive(Data(p + pdu))
    }

    private var address: [UInt8] { BLEController.address(for: peer) }

    func testAddressIsRandomStatic() {
        XCTAssertEqual(address, [0x12, 0x34, 0x56, 0x78, 0x9A, UInt8(0xBC) | 0xC0])
    }

    func testEverySupportedCommandIsHandled() {
        // (octet, bit) → opcode, from the Core spec's Supported Commands table.
        let table: [(Int, Int, UInt16)] = [
            (0, 5, 0x0406), (2, 7, 0x041D), (5, 6, 0x0C01), (5, 7, 0x0C03), (14, 3, 0x1001), (14, 5, 0x1003),
            (14, 7, 0x1005), (15, 1, 0x1009), (25, 0, 0x2001), (25, 1, 0x2002), (25, 2, 0x2003), (25, 4, 0x2005),
            (25, 5, 0x2006), (25, 6, 0x2007), (25, 7, 0x2008), (26, 0, 0x2009), (26, 1, 0x200A), (26, 2, 0x200B),
            (26, 3, 0x200C), (26, 4, 0x200D), (26, 5, 0x200E), (26, 6, 0x200F), (26, 7, 0x2010), (27, 0, 0x2011),
            (27, 1, 0x2012), (27, 2, 0x2013), (27, 5, 0x2016), (28, 3, 0x201C),
        ]
        var bits = [UInt8](repeating: 0, count: 64)
        for (octet, bit, opcode) in table {
            bits[octet] |= 1 << bit
            out = []
            cmd(opcode, [UInt8](repeating: 0, count: 25))
            let unknown = out.contains { $0[1] == 0x0E && $0.u16(4) == opcode && $0[6] == 0x01 }
            XCTAssertFalse(unknown, String(format: "%04X", opcode))
        }
        XCTAssertEqual(bits, BLEController.supportedCommands)
        cmd(0x1002)
        XCTAssertEqual(completed(0x1002), [0] + bits)
    }

    func testInitSequenceAnswers() {
        cmd(0x1003)
        XCTAssertEqual(completed(0x1003), [0, 0, 0, 0, 0, 0x60, 0, 0, 0])
        cmd(0x1001)
        XCTAssertEqual(completed(0x1001)?[1], 0x08)
        cmd(0x1009)
        XCTAssertEqual(completed(0x1009), [0, 1, 2, 3, 4, 5, 6])
        cmd(0x2002)
        XCTAssertEqual(completed(0x2002), [0, 251, 0, 8])
        cmd(0xFC01)
        XCTAssertEqual(completed(0xFC01), [0x01])
    }

    func testScanReportsAdvertisements() {
        cmd(0x200B, [1, 0x10, 0, 0x10, 0, 0, 0])
        cmd(0x200C, [1, 1])
        XCTAssertEqual(radio.scans, [false])
        let ad = BLEAdvertisement(localName: "A Rather Long Heart Rate Monitor Name", serviceUUIDs: [heartRate],
                                  manufacturerData: Data([0x4C, 0x00, 1, 2]), rssi: -60)
        controller.radio(discovered: peer, ad)
        let reports = leEvents(0x02)
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(Array(reports[0][0...8]), [1, 0x00, 0x01] + address)
        let adv = Array(reports[0][10..<(10 + Int(reports[0][9]))])
        XCTAssertEqual(Array(adv[0..<3]), [2, 0x01, 0x06])
        XCTAssertEqual(Array(adv[3..<7]), [3, 0x03, 0x0D, 0x18])
        XCTAssertEqual(Int8(bitPattern: reports[0].last!), -60)
        XCTAssertEqual(reports[1][1], 0x04)  // the name went into the scan response
        cmd(0x200C, [0, 0])
        XCTAssertEqual(radio.stops, 1)
        controller.radio(discovered: peer, ad)
        XCTAssertEqual(leEvents(0x02).count, 2)
    }

    func testShortensNamesThatDontFit() {
        let name = String(repeating: "é", count: 40)
        let (adv, rsp) = AdvertisingData.build(BLEAdvertisement(localName: name, isConnectable: false))
        XCTAssertTrue(rsp.isEmpty)
        XCTAssertEqual(adv[1], 0x08)
        XCTAssertEqual(adv.count, 30)  // 28 bytes of whole two-byte characters
        XCTAssertEqual(String(decoding: adv[2...], as: UTF8.self), String(repeating: "é", count: 14))
    }

    /// LE Create Connection parameters for `address`: interval 0x0018, latency 0, timeout 0x01F4.
    private func createConnection(to address: [UInt8], filterPolicy: UInt8 = 0) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 25)
        p[4] = filterPolicy
        p[5] = 1
        p.replaceSubrange(6...11, with: address)
        p[13] = 0x18; p[15] = 0x18      // interval min, max
        p[19] = 0xF4; p[20] = 0x01      // supervision timeout
        return p
    }

    private func connect(extra: [GATTCharacteristic] = []) -> UInt16 {
        controller.radio(discovered: peer, BLEAdvertisement(localName: "HRM"))
        cmd(0x200D, createConnection(to: address))
        XCTAssertEqual(radio.connects, [peer])
        controller.radio(connected: peer, name: "Polar H10", services: [
            GATTService(uuid: heartRate, characteristics: [
                GATTCharacteristic(id: 1, uuid: measurement, properties: 0x10),
                GATTCharacteristic(id: 2, uuid: location, properties: 0x0A),
            ] + extra),
        ])
        let complete = leEvents(0x01).last!
        XCTAssertEqual(complete[0], 0)
        XCTAssertEqual(Array(complete[5...10]), address)
        XCTAssertEqual(complete.u16(11), 0x0018)  // interval
        XCTAssertEqual(complete.u16(13), 0)       // latency
        XCTAssertEqual(complete.u16(15), 0x01F4)  // supervision timeout
        return complete.u16(1)
    }

    func testGATTDiscoveryReadWriteAndNotify() {
        let h = connect()
        sendATT(h, [0x02, 0x05, 0x02])
        XCTAssertEqual(att(h).last, [0x03, 247, 0])
        // Number Of Completed Packets for each ACL packet.
        XCTAssertTrue(out.contains { $0[1] == 0x13 && $0.u16(4) == h })

        sendATT(h, [0x10, 1, 0, 0xFF, 0xFF, 0x00, 0x28])
        // GAP 1…5, Heart Rate 6…11 (decl, measurement decl+value+CCCD, location decl+value).
        XCTAssertEqual(att(h).last, [0x11, 6, 1, 0, 5, 0, 0x00, 0x18, 6, 0, 11, 0, 0x0D, 0x18])
        sendATT(h, [0x10, 12, 0, 0xFF, 0xFF, 0x00, 0x28])
        XCTAssertEqual(att(h).last, [0x01, 0x10, 12, 0, 0x0A])

        sendATT(h, [0x08, 6, 0, 11, 0, 0x03, 0x28])
        XCTAssertEqual(att(h).last, [0x09, 7, 7, 0, 0x10, 8, 0, 0x37, 0x2A, 10, 0, 0x0A, 11, 0, 0x38, 0x2A])
        sendATT(h, [0x04, 9, 0, 11, 0])
        XCTAssertEqual(att(h).last, [0x05, 0x01, 9, 0, 0x02, 0x29, 10, 0, 0x03, 0x28, 11, 0, 0x38, 0x2A])

        sendATT(h, [0x0A, 3, 0])
        XCTAssertEqual(att(h).last, [0x0B] + [UInt8]("Polar H10".utf8))
        radio.values[.characteristic(2)] = Data([0x01])
        sendATT(h, [0x0A, 11, 0])
        XCTAssertEqual(att(h).last, [0x0B, 0x01])
        sendATT(h, [0x0A, 8, 0])
        XCTAssertEqual(att(h).last, [0x01, 0x0A, 8, 0, 0x02])

        sendATT(h, [0x12, 11, 0, 0x02])
        XCTAssertEqual(att(h).last, [0x13])
        XCTAssertEqual(radio.writes.last?.0, .characteristic(2))
        sendATT(h, [0x12, 8, 0, 0x02])
        XCTAssertEqual(att(h).last, [0x01, 0x12, 8, 0, 0x03])

        sendATT(h, [0x12, 9, 0, 0x01, 0x00])
        XCTAssertEqual(att(h).last, [0x13])
        XCTAssertEqual(radio.notify.last?.0, 1)
        XCTAssertEqual(radio.notify.last?.1, true)
        sendATT(h, [0x0A, 9, 0])
        XCTAssertEqual(att(h).last, [0x0B, 0x01, 0x00])
        controller.radio(notified: peer, characteristic: 1, value: Data([0x00, 72]))
        XCTAssertEqual(att(h).last, [0x1B, 8, 0, 0x00, 72])

        sendATT(h, [0x20, 1, 0])
        XCTAssertEqual(att(h).last, [0x01, 0x20, 0, 0, 0x06])

        out = []
        cmd(0x0406, [UInt8(h & 0xFF), UInt8(h >> 8), 0x13])
        XCTAssertEqual(radio.disconnects, [peer])
        XCTAssertEqual(out.last, [0x04, 0x05, 4, 0, UInt8(h & 0xFF), UInt8(h >> 8), 0x16])
    }

    func testReassemblesFragmentedACLAndPreparedWrites() {
        let h = connect()
        // Prepare Write split across two ACL fragments.
        let pdu: [UInt8] = [0x16, 11, 0, 0, 0, 0xAA, 0xBB]
        var first: [UInt8] = [0x02]
        first.put16(h); first.put16(6); first.put16(UInt16(pdu.count)); first.put16(4)
        controller.receive(Data(first + pdu[0..<2]))
        XCTAssertTrue(att(h).isEmpty)
        var cont: [UInt8] = [0x02]
        cont.put16(h | 0x1000); cont.put16(UInt16(pdu.count - 2))
        controller.receive(Data(cont + pdu[2...]))
        XCTAssertEqual(att(h).last, [0x17, 11, 0, 0, 0, 0xAA, 0xBB])
        sendATT(h, [0x16, 11, 0, 2, 0, 0xCC])
        sendATT(h, [0x18, 0x01])
        XCTAssertEqual(att(h).last, [0x19])
        XCTAssertEqual(radio.writes.last?.1, Data([0xAA, 0xBB, 0xCC]))
    }

    func testSecurityAndSignalingAreRefused() {
        let h = connect()
        var smp: [UInt8] = [0x02]
        smp.put16(h); smp.put16(11); smp.put16(7); smp.put16(6)
        controller.receive(Data(smp + [0x01, 0x03, 0x00, 0x01, 0x10, 0x07, 0x07]))
        XCTAssertEqual(Array(out.last![5...]), [2, 0, 6, 0, 0x05, 0x05])
        var sig: [UInt8] = [0x02]
        sig.put16(h); sig.put16(10); sig.put16(6); sig.put16(5)
        controller.receive(Data(sig + [0x0A, 7, 2, 0, 2, 0]))
        XCTAssertEqual(Array(out.last![5...]), [6, 0, 5, 0, 0x01, 7, 2, 0, 0, 0])
    }

    func testConnectingToAnUnseenAddressScansForIt() {
        cmd(0x200D, createConnection(to: address))
        XCTAssertTrue(radio.connects.isEmpty)
        XCTAssertEqual(radio.scans, [false])
        controller.radio(discovered: peer, BLEAdvertisement())
        XCTAssertEqual(radio.connects, [peer])
        XCTAssertEqual(radio.stops, 1)
        XCTAssertTrue(leEvents(0x02).isEmpty)  // the guest isn't scanning

        cmd(0x200E)
        XCTAssertEqual(completed(0x200E), [0])
        XCTAssertEqual(leEvents(0x01).last?[0], 0x02)
        XCTAssertEqual(radio.disconnects, [peer])
    }

    func testRadioLossDropsConnections() {
        let h = connect()
        var reason: String?
        controller.onUnavailable = { reason = $0 }
        controller.radio(unavailable: "Bluetooth is off")
        XCTAssertEqual(reason, "Bluetooth is off")
        XCTAssertEqual(out.last, [0x04, 0x05, 4, 0, UInt8(h & 0xFF), UInt8(h >> 8), 0x08])
        sendATT(h, [0x0A, 3, 0])
        XCTAssertEqual(att(h).count, 0)
    }

    func testLocalNameIsAlways248Bytes() {
        cmd(0x0C13, [UInt8](repeating: 0x41, count: 255))
        XCTAssertEqual(completed(0x0C13), [0x12])
        cmd(0x0C14)
        XCTAssertEqual(completed(0x0C14), [0] + [UInt8](repeating: 0, count: 248))
        let name = [UInt8]("vitrine-guest".utf8)
        cmd(0x0C13, name + [UInt8](repeating: 0, count: 248 - name.count))
        XCTAssertEqual(completed(0x0C13), [0])
        cmd(0x0C14)
        XCTAssertEqual(completed(0x0C14), [0] + name + [UInt8](repeating: 0, count: 248 - name.count))
    }

    func testAcceptListConnectsToWhicheverListedDeviceAdvertises() {
        let unlisted = UUID(uuidString: "AABBCCDD-0000-0000-0000-000000000000")!
        cmd(0x2011, [1, 0x11, 0x11, 0x11, 0x11, 0x11, 0xD1])  // never turns up
        cmd(0x2011, [1] + address)
        cmd(0x200D, createConnection(to: [UInt8](repeating: 0, count: 6), filterPolicy: 1))
        XCTAssertEqual(radio.scans, [false])
        controller.radio(discovered: unlisted, BLEAdvertisement())
        controller.radio(discovered: peer, BLEAdvertisement(isConnectable: false))
        XCTAssertTrue(radio.connects.isEmpty)
        controller.radio(discovered: peer, BLEAdvertisement())
        XCTAssertEqual(radio.connects, [peer])
        controller.radio(connected: peer, name: nil, services: [])
        let complete = leEvents(0x01).last!
        XCTAssertEqual(complete[0], 0)
        XCTAssertEqual(Array(complete[5...10]), address)
    }

    func testClientConfigurationMatchesPropertiesAndIndicationsWaitForConfirmation() {
        // Alert Level, read + indicate: declaration 12, value 13, CCCD 14.
        let h = connect(extra: [GATTCharacteristic(id: 3, uuid: BTUUID(0x2A06), properties: 0x22)])
        sendATT(h, [0x12, 9, 0, 0x02, 0x00])  // indications from a notify-only characteristic
        XCTAssertEqual(att(h).last, [0x01, 0x12, 9, 0, 0xFD])
        sendATT(h, [0x12, 14, 0, 0x01, 0x00])  // notifications from an indicate-only one
        XCTAssertEqual(att(h).last, [0x01, 0x12, 14, 0, 0xFD])
        XCTAssertTrue(radio.notify.isEmpty)

        controller.radio(notified: peer, characteristic: 3, value: Data([1]))  // not subscribed: dropped
        XCTAssertEqual(att(h).last, [0x01, 0x12, 14, 0, 0xFD])

        sendATT(h, [0x12, 14, 0, 0x02, 0x00])
        XCTAssertEqual(att(h).last, [0x13])
        XCTAssertEqual(radio.notify.last?.0, 3)
        controller.radio(notified: peer, characteristic: 3, value: Data([1]))
        controller.radio(notified: peer, characteristic: 3, value: Data([2]))
        let indications = { self.att(h).filter { $0[0] == 0x1D } }
        XCTAssertEqual(indications(), [[0x1D, 13, 0, 1]])
        sendATT(h, [0x1E])
        XCTAssertEqual(indications(), [[0x1D, 13, 0, 1], [0x1D, 13, 0, 2]])
        sendATT(h, [0x1E])
        XCTAssertEqual(indications().count, 2)
    }

    func testValueAnswersPendingReadAndStillNotifiesWhileSubscribed() {
        var reads: [Result<Data, ATTError>] = [], notes: [Data] = []
        let read: (Result<Data, ATTError>) -> Void = { reads.append($0) }
        CoreBluetoothRadio.deliver(.success(Data([1])), read: read, notifying: true) { notes.append($0) }
        XCTAssertEqual(reads, [.success(Data([1]))])
        XCTAssertEqual(notes, [Data([1])])
        CoreBluetoothRadio.deliver(.success(Data([2])), read: read, notifying: false) { notes.append($0) }
        XCTAssertEqual(reads.last, .success(Data([2])))
        XCTAssertEqual(notes, [Data([1])])
        // No read waiting: a notification, as before.
        CoreBluetoothRadio.deliver(.success(Data([3])), read: nil, notifying: true) { notes.append($0) }
        XCTAssertEqual(notes, [Data([1]), Data([3])])
        CoreBluetoothRadio.deliver(.failure(.readNotPermitted), read: read, notifying: true) { notes.append($0) }
        XCTAssertEqual(reads.last, .failure(.readNotPermitted))
        XCTAssertEqual(notes.count, 2)
    }
}
