import XCTest
@testable import VitrineAgentHost

/// A peripheral that never answers reads: requests pile up behind the first one.
private final class StalledRadio: BLERadio {
    weak var delegate: BLERadioDelegate?
    var reads = 0
    func startScan(allowDuplicates: Bool) {}
    func stopScan() {}
    func connect(_ peer: UUID) {}
    func disconnect(_ peer: UUID) {}
    func read(_ peer: UUID, _ target: GATTTarget, completion: @escaping (Result<Data, ATTError>) -> Void) { reads += 1 }
    func write(_ peer: UUID, _ target: GATTTarget, value: Data, withResponse: Bool,
               completion: @escaping (Result<Void, ATTError>) -> Void) {}
    var notifies = 0
    func setNotify(_ peer: UUID, characteristic: Int, enabled: Bool, completion: @escaping (Result<Void, ATTError>) -> Void) { notifies += 1 }
    func stop() {}
}

final class ATTServerLimitsTests: XCTestCase {
    func testAClientThatDoesntWaitGetsErrorsNotAGrowingQueue() {
        let radio = StalledRadio()
        var out: [[UInt8]] = []
        // GAP 1…5, then the service at 6, its characteristic declaration at 7 and value at 8.
        let server = ATTServer(peer: UUID(), name: "x", services: [
            GATTService(uuid: BTUUID(0x180D), characteristics: [GATTCharacteristic(id: 1, uuid: BTUUID(0x2A38), properties: 0x02)]),
        ], radio: radio) { out.append($0) }
        let extra = 7
        for _ in 0..<(1 + ATTServer.maxQueuedRequests + extra) { server.receive([0x0A, 8, 0]) }
        XCTAssertEqual(radio.reads, 1)  // one at a time
        XCTAssertEqual(out.count, extra)
        XCTAssertTrue(out.allSatisfy { $0 == [0x01, 0x0A, 8, 0, ATTError.unlikelyError.rawValue] })
    }

    func testSubscriptionsNeedAWriteRequest() {
        let radio = StalledRadio()
        var out: [[UInt8]] = []
        // GAP 1…5, service 6, declaration 7, value 8, CCCD 9 (notify property).
        let server = ATTServer(peer: UUID(), name: "x", services: [
            GATTService(uuid: BTUUID(0x180D), characteristics: [GATTCharacteristic(id: 1, uuid: BTUUID(0x2A37), properties: 0x10)]),
        ], radio: radio) { out.append($0) }
        for _ in 0..<100 { server.receive([0x52, 9, 0, 1, 0]) }  // Write Commands: dropped
        XCTAssertEqual(radio.notifies, 0)
        XCTAssertTrue(out.isEmpty)
        server.receive([0x12, 9, 0, 1, 0])  // a Write Request subscribes
        XCTAssertEqual(radio.notifies, 1)
    }
}

