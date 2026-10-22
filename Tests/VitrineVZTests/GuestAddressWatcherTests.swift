import XCTest
@testable import VitrineVZ
import VitrineCore

final class GuestAddressWatcherTests: XCTestCase {
    private let mac: [UInt8] = [0xd2, 0x91, 0x8d, 0x80, 0x1a, 0x95]

    private func frame(from source: [UInt8], ip: String) -> [UInt8] {
        let octets = ip.split(separator: ".").map { UInt8($0)! }
        // Built in steps: Swift 6.2 times out type-checking one long concatenation.
        var f = [UInt8](repeating: 0xff, count: 6)
        f += source
        f += [0x08, 0x00]
        f += [0x45, 0, 0, 20, 0, 0, 0, 0, 64, 17, 0, 0]
        f += octets
        f += [192, 168, 1, 1]
        return f
    }

    func testLearnsKeepsAndReplacesTheAddress() throws {
        var recorded: [String] = [], checked: [String] = []
        let watcher = try XCTUnwrap(GuestAddressWatcher(mac: "d2:91:8d:80:1a:95",
            accept: { checked.append($0); return $0.hasPrefix("192.168.1.") }, record: { recorded.append($0) }))
        let hold = GuestAddressWatcher.holdNanos
        func send(_ ip: String, at t: UInt64, from source: [UInt8]? = nil) {
            frame(from: source ?? mac, ip: ip).withUnsafeBytes { watcher.observe($0, now: t) }
        }
        XCTAssertNil(watcher.address)
        send("0.0.0.0", at: 1)
        send("172.17.0.2", at: 1, from: [2, 0x42, 0xac, 0x11, 0, 2])
        XCTAssertEqual(checked, [], "frames that carry no address of the VM's adapter aren't checked")
        send("8.8.8.8", at: 2)
        send("8.8.8.8", at: 3)
        XCTAssertEqual(checked, ["8.8.8.8"], "a refusal is remembered")
        XCTAssertNil(watcher.address)
        send("192.168.1.23", at: 4)
        send("192.168.1.23", at: 5)
        XCTAssertEqual(recorded, ["192.168.1.23"], "recorded once")
        XCTAssertEqual(watcher.address, "192.168.1.23")
        send("192.168.1.99", at: 5 + hold - 1)
        XCTAssertEqual(watcher.address, "192.168.1.23", "another address doesn't replace one in use")
        send("192.168.1.99", at: 5 + hold + 1)
        XCTAssertEqual(watcher.address, "192.168.1.99", "it does once the old one has gone unused")
        XCTAssertEqual(recorded, ["192.168.1.23", "192.168.1.99"])
        XCTAssertNil(GuestAddressWatcher(mac: "not a mac", accept: { _ in true }, record: { _ in }))
    }
}
