import XCTest
@testable import VitrineVZ
import VitrineCore

final class SerialConsoleBridgeTests: XCTestCase {
    // The app and vitrinectl ignore SIGPIPE; without that, writing to a pipe whose reader is gone
    // kills the test process instead of failing the write.
    override class func setUp() {
        super.setUp()
        signal(SIGPIPE, SIG_IGN)
    }

    private func makeBundle() throws -> VMBundle {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("serial-\(UUID().uuidString.prefix(8)).vitrinevm")
        return try VMBundle.create(at: dir, config: VMConfig(name: "serial"))
    }

    private func readyClient(_ bundle: VMBundle, bridge: SerialConsoleBridge) throws -> Int32 {
        let fd = try UnixSocket.connect(path: bundle.socketDirectory.appendingPathComponent("serial.sock").path)
        XCTAssertTrue(UnixSocket.writeAll(fd, Data([42])))
        var p = pollfd(fd: bridge.toGuest.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, 2000) > 0 else {
            Darwin.close(fd)
            throw VitrineError.io("console did not accept input")
        }
        var byte: UInt8 = 0
        XCTAssertEqual(read(p.fd, &byte, 1), 1)
        XCTAssertEqual(byte, 42)
        return fd
    }

    func testReplacementReceivesOutputAndStopReleasesBridge() throws {
        let b = try makeBundle()
        defer { SerialConsoleBridge.stop(bundle: b); try? FileManager.default.removeItem(at: b.url) }
        var bridge: SerialConsoleBridge? = try SerialConsoleBridge.start(bundle: b)
        weak var weakBridge = bridge
        let first = try readyClient(b, bridge: bridge!)
        defer { Darwin.close(first) }
        let second = try readyClient(b, bridge: bridge!)
        defer { Darwin.close(second) }
        try bridge!.fromGuest.fileHandleForWriting.write(contentsOf: Data("console".utf8))
        var p = pollfd(fd: second, events: Int16(POLLIN), revents: 0)
        XCTAssertGreaterThan(poll(&p, 1, 2000), 0)
        var bytes = [UInt8](repeating: 0, count: 7)
        XCTAssertEqual(read(second, &bytes, bytes.count), 7)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "console")
        SerialConsoleBridge.stop(bundle: b)
        bridge = nil
        XCTAssertNil(weakBridge)
        XCTAssertEqual(try String(contentsOf: b.consoleLogURL, encoding: .utf8), "console")
    }

    func testBackpressureDoesNotKeepStoppedBridgeAlive() throws {
        let b = try makeBundle()
        defer { SerialConsoleBridge.stop(bundle: b); try? FileManager.default.removeItem(at: b.url) }
        var bridge: SerialConsoleBridge? = try SerialConsoleBridge.start(bundle: b)
        weak var weakBridge = bridge
        let client = try readyClient(b, bridge: bridge!)
        defer { Darwin.close(client) }
        let output = bridge!.fromGuest.fileHandleForWriting.fileDescriptor
        for fd in [client, output] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        let data = [UInt8](repeating: 65, count: 4096)
        // Neither the guest input pipe nor the console socket is drained during this flood.
        for _ in 0..<300 {
            _ = data.withUnsafeBytes { Darwin.write(client, $0.baseAddress!, $0.count) }
            _ = data.withUnsafeBytes { Darwin.write(output, $0.baseAddress!, $0.count) }
            Thread.sleep(forTimeInterval: 0.001)
        }
        SerialConsoleBridge.stop(bundle: b)
        let inputHandle = bridge!.toGuest.fileHandleForWriting
        bridge = nil
        XCTAssertNil(weakBridge)
        XCTAssertThrowsError(try inputHandle.write(contentsOf: Data([0])))
    }
}
