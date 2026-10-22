import XCTest
import vmnet
@testable import VitrineVZ
@testable import VitrineNet
import VitrineCore

final class NetworkPlumbingTests: XCTestCase {
    func testSerializationRoundTrips() throws {
        let d = xpc_dictionary_create(nil, nil, 0)
        let bytes: [UInt8] = [0, 1, 2, 250, 255]
        xpc_dictionary_set_data(d, "blob", bytes, bytes.count)
        xpc_dictionary_set_string(d, "s", "lab")
        xpc_dictionary_set_uint64(d, "u", .max)
        xpc_dictionary_set_int64(d, "i", -5)
        xpc_dictionary_set_bool(d, "b", true)
        var uuid = UUID().uuid
        withUnsafeBytes(of: &uuid) { xpc_dictionary_set_uuid(d, "id", $0.bindMemory(to: UInt8.self).baseAddress!) }
        let flat = try XCTUnwrap(NetworkOwner.encode(d))
        let json = try JSONDecoder().decode([String: [String]].self, from: JSONEncoder().encode(flat))
        let back = try XCTUnwrap(NetworkOwner.decode(json))
        XCTAssertTrue(xpc_equal(d, back))
        XCTAssertNil(NetworkOwner.decode(["x": ["data", "not base64!"]]))
        XCTAssertNil(NetworkOwner.decode(["x": ["fd", "3"]]))
        let withArray = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(withArray, "a", xpc_array_create(nil, 0))
        XCTAssertNil(NetworkOwner.encode(withArray), "unknown value types aren't flattened")
    }

    func testNetworkKeys() throws {
        var c = VMConfig(name: "x", guestOS: .linux, cpuCount: 1, memoryMiB: 1024)
        c.network.mode = .hostOnly
        XCTAssertEqual(try VmnetNetworks.key(for: c), "host-only")
        c.network.mode = .nat
        XCTAssertThrowsError(try VmnetNetworks.key(for: c))
        c.network.mode = .network
        XCTAssertThrowsError(try VmnetNetworks.key(for: c), "no name")
        XCTAssertEqual(VmnetNetworks.definition(forKey: "host-only")?.kind, .hostOnly)
        XCTAssertNil(VmnetNetworks.definition(forKey: "bogus"))
        XCTAssertEqual(NetworkOwner.display("net:lab"), "network “lab”")
    }

    /// Frames split across reads and several frames per read come out whole and in order.
    func testStreamFraming() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let reader = FrameSocket(fd: fds[0], framing: .stream)
        let writer = FrameSocket(fd: fds[1], framing: .stream)
        let frames: [[UInt8]] = (0..<300).map { i in (0..<(60 + i * 7 % 1500)).map { UInt8(truncatingIfNeeded: $0 &+ i) } }
        var got: [[UInt8]] = []
        let done = expectation(description: "frames")
        reader.onFrames(queue: DispatchQueue(label: "t"), { buf in
            got.append(Array(buf))
            if got.count == frames.count { done.fulfill() }
        }, onClose: {})
        DispatchQueue.global().async {
            for f in frames { f.withUnsafeBytes { _ = writer.write($0) } }
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(got, frames)
        writer.close()
        reader.close()
    }

    /// A stream that announces an absurd length is dropped instead of buffering forever.
    func testOversizedFrameClosesTheStream() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let reader = FrameSocket(fd: fds[0], framing: .stream)
        let closed = expectation(description: "closed")
        reader.onFrames(queue: DispatchQueue(label: "t"), { _ in XCTFail("no frame expected") }, onClose: { closed.fulfill() })
        var header = UInt32(10 << 20).bigEndian
        _ = withUnsafeBytes(of: &header) { write(fds[1], $0.baseAddress, 4) }
        wait(for: [closed], timeout: 5)
        close(fds[1])
    }

    func testDatagramFraming() throws {
        let (a, b) = try UnixSocket.datagramPair()
        let reader = FrameSocket(fd: a, framing: .datagram)
        let writer = FrameSocket(fd: b, framing: .datagram)
        let frame = [UInt8](repeating: 0xAB, count: 1514)
        let got = expectation(description: "frame")
        reader.onFrames(queue: DispatchQueue(label: "t"), { buf in
            XCTAssertEqual(Array(buf), frame)
            got.fulfill()
        }, onClose: {})
        frame.withUnsafeBytes { _ = writer.write($0) }
        wait(for: [got], timeout: 5)
        writer.close()
        reader.close()
    }

    func testBridgeSocketDiscovery() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("br-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        setenv("VITRINE_BRIDGE_DIR", dir.path, 1)
        defer { unsetenv("VITRINE_BRIDGE_DIR") }
        XCTAssertNil(BridgeSockets.socket(for: "en9"))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("bridged.en9").path, contents: nil)
        XCTAssertNil(BridgeSockets.socket(for: "en9"), "a plain file is not a socket")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("bridged.en9"))
        let fd = try UnixSocket.listen(path: dir.appendingPathComponent("bridged.en9").path)
        defer { close(fd) }
        XCTAssertEqual(BridgeSockets.socket(for: "en9")?.provider, .vitrine)
        XCTAssertNil(BridgeSockets.socket(for: "../en9"))
    }
}
