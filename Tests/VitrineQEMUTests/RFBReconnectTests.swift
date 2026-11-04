import XCTest
import Darwin
@testable import VitrineQEMU
import VitrineCore

/// A VNC session that fails (a message the client can't parse, a dropped socket) must not leave the
/// display frozen on its last frame while the VM keeps running: the client reconnects to the same
/// server and carries on with the same framebuffer and callbacks.
final class RFBReconnectTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        signal(SIGPIPE, SIG_IGN)
    }

    func testReconnectsAfterAProtocolError() throws {
        let path = NSTemporaryDirectory() + "rfb-\(UUID().uuidString.prefix(8)).sock"
        let listener = try UnixSocket.listen(path: path)
        defer { Darwin.close(listener); unlink(path) }

        let connections = Counter()
        let server = Thread {
            // First session: handshake, then a rectangle in an encoding the client never asked for.
            guard let a = Self.acceptAndHandshake(listener) else { return }
            connections.increment()
            Self.drainRequests(a)
            _ = UnixSocket.writeAll(a, Self.update(encoding: 7, pixel: nil))
            // Second session: a real frame.
            guard let b = Self.acceptAndHandshake(listener) else { Darwin.close(a); return }
            connections.increment()
            Self.drainRequests(b)
            _ = UnixSocket.writeAll(b, Self.update(encoding: 0, pixel: [0x10, 0x20, 0x30, 0x00]))
            Thread.sleep(forTimeInterval: 2)
            Darwin.close(a); Darwin.close(b)
        }
        server.start()

        let client = try RFBClient(socketPath: path, timeout: 3)
        defer { client.close() }
        let painted = expectation(description: "frame after reconnecting")
        client.onFrame = { _ in painted.fulfill() }
        client.start()
        wait(for: [painted], timeout: 5)
        XCTAssertEqual(connections.value, 2)

        let s = client.framebuffer.snapshot()
        let surface = try XCTUnwrap(s.surface)
        surface.lock(options: .readOnly, seed: nil)
        let p = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual([p[0], p[1], p[2], p[3]], [0x10, 0x20, 0x30, 0xFF])
        surface.unlock(options: .readOnly, seed: nil)
    }

    func testCloseStopsReconnecting() throws {
        let path = NSTemporaryDirectory() + "rfb-\(UUID().uuidString.prefix(8)).sock"
        let listener = try UnixSocket.listen(path: path)
        defer { Darwin.close(listener); unlink(path) }
        let connections = Counter()
        let server = Thread {
            while let fd = Self.acceptAndHandshake(listener) {
                connections.increment()
                Self.drainRequests(fd)
                Darwin.close(fd)  // every session drops right after it starts
            }
        }
        server.start()

        let client = try RFBClient(socketPath: path, timeout: 3)
        client.start()
        Thread.sleep(forTimeInterval: 0.8)
        client.close()
        let afterClose = connections.value
        XCTAssertGreaterThanOrEqual(afterClose, 2, "never reconnected")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(connections.value, afterClose, "kept reconnecting after close()")
        shutdown(listener, SHUT_RDWR)
    }

    // MARK: Fake VNC server (1x1 display, no security)

    private static func acceptAndHandshake(_ listener: Int32) -> Int32? {
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(listener, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard UnixSocket.writeAll(fd, Data("RFB 003.008\n".utf8)), read(fd, 12) != nil,
              UnixSocket.writeAll(fd, Data([1, 1])), read(fd, 1) != nil,      // security types: None
              UnixSocket.writeAll(fd, Data([0, 0, 0, 0])), read(fd, 1) != nil  // security result, ClientInit
        else { Darwin.close(fd); return nil }
        var initMsg = Data([0, 1, 0, 1])                                       // 1x1
        initMsg += Data(count: 16)                                             // pixel format
        initMsg += Data([0, 0, 0, 0])                                          // empty name
        guard UnixSocket.writeAll(fd, initMsg) else { Darwin.close(fd); return nil }
        return fd
    }

    /// Reads SetPixelFormat, SetEncodings and the first update request.
    private static func drainRequests(_ fd: Int32) {
        _ = read(fd, 20)
        guard let head = read(fd, 4) else { return }
        _ = read(fd, Int(head[2]) << 8 | Int(head[3]) * 4)
        _ = read(fd, 10)
    }

    private static func update(encoding: Int32, pixel: [UInt8]?) -> Data {
        var m = Data([0, 0, 0, 1])                                             // FramebufferUpdate, 1 rect
        m += Data([0, 0, 0, 0, 0, 1, 0, 1])                                    // x, y, w=1, h=1
        withUnsafeBytes(of: encoding.bigEndian) { m += $0 }
        if let pixel { m += pixel }
        return m
    }

    private static func read(_ fd: Int32, _ count: Int) -> Data? {
        var buf = [UInt8](repeating: 0, count: count), off = 0
        while off < count {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + off, count - off) }
            guard n > 0 else { return nil }
            off += n
        }
        return Data(buf)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
