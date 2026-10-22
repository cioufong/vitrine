import XCTest
import Compression
@testable import VitrineAgentProtocol
@testable import VitrineAgentHost

final class ProtocolTests: XCTestCase {
    func roundTrip(_ m: AgentMessage, file: StaticString = #filePath, line: UInt = #line) throws {
        var d = MessageDeframer()
        d.append(try AgentCodec.encode(m))
        XCTAssertEqual(try d.next(), m, file: file, line: line)
        XCTAssertNil(try d.next(), file: file, line: line)
    }

    func testAllMessagesRoundTrip() throws {
        try roundTrip(.hello(Hello(role: "guest", os: "macOS 27.0", agentVersion: "0.1", capabilities: ["coherence"])))
        try roundTrip(.windowList(WindowList(windows: [
            WindowInfo(id: 42, pid: 100, appName: "Safari", bundleID: "com.apple.Safari", title: "Apple",
                       frame: Rect(x: 10, y: 40, width: 800, height: 600), layer: 0, kind: .normal, isFocused: true),
        ])))
        try roundTrip(.displayInfo(DisplayInfo(widthPoints: 1512, heightPoints: 982, scale: 2, menuBarHeight: 37)))
        try roundTrip(.frame(FrameUpdate(surfaceWidth: 8, surfaceHeight: 8, x: 2, y: 3, width: 2, height: 2,
                                         data: Data(repeating: 0xAB, count: 16))))
        try roundTrip(.pointer(PointerEvent(kind: .scroll, button: .right, clickCount: 2, x: 1.5, y: -3.25,
                                            scrollDX: 4, scrollDY: -8, modifiers: 0x100000, preciseScroll: true)))
        try roundTrip(.key(KeyEvent(keyCode: 0x24, down: true, modifiers: 0x20000)))
        try roundTrip(.key(KeyEvent(keyCode: 0, down: true, modifiers: 0, text: "你好😀")))
        try roundTrip(.windowAction(WindowAction(windowID: 7, action: .move, frame: Rect(x: 1, y: 2, width: 3, height: 4))))
        try roundTrip(.setCoherence(CoherenceRequest(enabled: true, maxFPS: 30)))
        try roundTrip(.fileDrop(FileDrop(files: ["a1b2/報告.pdf", "a1b2/photo.png"], x: 120, y: 340)))
        try roundTrip(.fileDrop(FileDrop(files: ["b/x.txt"])))
        try roundTrip(.clipboard(ClipboardContent(items: [.init(type: "public.utf8-plain-text", data: Data("hi".utf8))])))
        try roundTrip(.ping(.max))
        try roundTrip(.pong(1))
        try roundTrip(.log("hello ✓"))
        try roundTrip(.guestStats(GuestStats(cpuPercent: 12.5, memoryUsed: 1 << 30, memoryTotal: 4 << 30, uptimeSeconds: 90)))
        try roundTrip(.cameraStart(CameraStart(width: 1280, height: 720, fps: 30)))
        try roundTrip(.cameraFrame(CameraFrame(width: 2, height: 2, data: Data(1...8))))
        try roundTrip(.cameraStop)
        try roundTrip(.cameraStatus(CameraStatus(ready: false, error: "v4l2loopback is not loaded")))
        try roundTrip(.bluetoothStart)
        try roundTrip(.bluetoothHCI(Data([1, 0x03, 0x0C, 0])))
        try roundTrip(.bluetoothStop)
        try roundTrip(.bluetoothStatus(BluetoothStatus(ready: true, device: "hci0")))
        try roundTrip(.requestPermissions)
    }

    func testCameraWireFormatMatchesGoAgent() throws {
        // guest/linux-agent/protocol: u32 width, u32 height, then the YUYV bytes.
        let wire = try AgentCodec.encode(.cameraFrame(CameraFrame(width: 2, height: 1, data: Data([1, 2, 3, 4]))))
        XCTAssertEqual([UInt8](wire), [13, 0, 0, 0, 0x2D, 2, 0, 0, 0, 1, 0, 0, 0, 1, 2, 3, 4])
        // What the Go agent's CameraStatus marshals to (empty strings omitted).
        let ok = try AgentCodec.decode(type: MessageType.cameraStatus.rawValue, payload: Data(#"{"device":"/dev/video0","ready":true}"#.utf8))
        XCTAssertEqual(ok, .cameraStatus(CameraStatus(ready: true, device: "/dev/video0")))
        if case .cameraStatus(let s) = ok { XCTAssertNil(s.installable) } // Go agents: Install Camera Support applies
        try roundTrip(.cameraStatus(CameraStatus(ready: false, error: "allow it in System Settings", installable: false)))
        // A frame whose length doesn't match its size, or an absurd size, is refused.
        var short = Data(); short.appendLE(UInt32(2)); short.appendLE(UInt32(2)); short.append(Data(count: 7))
        XCTAssertThrowsError(try AgentCodec.decode(type: MessageType.cameraFrame.rawValue, payload: short))
        XCTAssertThrowsError(try AgentCodec.decode(type: MessageType.cameraStart.rawValue,
                                                   payload: Data(#"{"width":100000,"height":10,"fps":30}"#.utf8)))
    }

    func testRejectsImplausibleGuestStats() throws {
        // What the Go agent sends: omitted fields stay nil.
        let ok = try AgentCodec.decode(type: MessageType.guestStats.rawValue, payload: Data(#"{"cpuPercent":3,"diskTotal":10,"diskUsed":4}"#.utf8))
        XCTAssertEqual(ok, .guestStats(GuestStats(cpuPercent: 3, diskUsed: 4, diskTotal: 10)))
        for bad in [#"{"cpuPercent":250}"#, #"{"memoryUsed":9,"memoryTotal":4}"#] {
            XCTAssertThrowsError(try AgentCodec.decode(type: MessageType.guestStats.rawValue, payload: Data(bad.utf8)), bad)
        }
    }

    func testDeframerHandlesSplitAndCoalescedReads() throws {
        let a = try AgentCodec.encode(.ping(1)), b = try AgentCodec.encode(.log("two")), c = try AgentCodec.encode(.pong(3))
        let all = a + b + c
        var d = MessageDeframer()
        var got: [AgentMessage] = []
        for byte in all { // worst case: one byte at a time
            d.append(Data([byte]))
            while let m = try d.next() { got.append(m) }
        }
        XCTAssertEqual(got, [.ping(1), .log("two"), .pong(3)])
        XCTAssertEqual(d.bufferedByteCount, 0)
    }

    func testRejectsGarbage() {
        var d = MessageDeframer()
        d.append(Data([2, 0, 0, 0, 0xEE, 0]))
        XCTAssertThrowsError(try d.next())
        var big = MessageDeframer()
        big.append(Data([0xFF, 0xFF, 0xFF, 0x7F, 1]))
        XCTAssertThrowsError(try big.next())
        // Frame claiming a rect outside its surface.
        var payload = Data()
        for v: UInt32 in [4, 4, 3, 3, 2, 2] { payload.appendLE(v) }
        payload.append(0)
        payload.append(Data(count: 16))
        XCTAssertThrowsError(try AgentCodec.decode(type: MessageType.frame.rawValue, payload: payload))
    }

    /// A hostile guest must not be able to trap the host with overflowing frame arithmetic.
    func testRejectsOverflowingFrames() {
        func frame(_ v: [UInt32]) -> Data {
            var p = Data(); for x in v { p.appendLE(x) }; p.append(0); return p
        }
        let cases: [[UInt32]] = [
            [16, 16, .max, 0, 1, 1],           // x + width overflows
            [1 << 31, 1 << 31, 0, 0, 1 << 31, 1 << 31], // w*h*4 overflows
            [0, 0, 0, 0, 0, 0],                // empty surface
            [20000, 20000, 0, 0, 1, 1],        // larger than any real display
        ]
        for c in cases {
            XCTAssertThrowsError(try AgentCodec.decode(type: MessageType.frame.rawValue, payload: frame(c)), "\(c)")
        }
    }

    func testGeometrySanity() {
        XCTAssertFalse(DisplayInfo(widthPoints: 0, heightPoints: 0, scale: 2, menuBarHeight: 0).isSane)
        XCTAssertFalse(DisplayInfo(widthPoints: .infinity, heightPoints: 900, scale: 2, menuBarHeight: 0).isSane)
        XCTAssertTrue(DisplayInfo(widthPoints: 1512, heightPoints: 982, scale: 2, menuBarHeight: 37).isSane)
        XCTAssertFalse(Rect(x: .nan, y: 0, width: 10, height: 10).isSane)
        XCTAssertTrue(Rect(x: -20, y: 30, width: 800, height: 600).isSane)
    }

    func testClipboardFingerprintIgnoresOrder() {
        let a = ClipboardContent(items: [.init(type: "a", data: Data([1])), .init(type: "b", data: Data([2]))])
        let b = ClipboardContent(items: [.init(type: "b", data: Data([2])), .init(type: "a", data: Data([1]))])
        XCTAssertEqual(a.fingerprint, b.fingerprint)
        XCTAssertNotEqual(a.fingerprint, ClipboardContent(items: [.init(type: "a", data: Data([9]))]).fingerprint)
    }

    func testRectMath() {
        let a = Rect(x: 0, y: 0, width: 10, height: 10), b = Rect(x: 5, y: 5, width: 10, height: 10)
        XCTAssertEqual(a.intersection(b), Rect(x: 5, y: 5, width: 5, height: 5))
        XCTAssertTrue(a.intersection(Rect(x: 20, y: 20, width: 1, height: 1)).isEmpty)
        XCTAssertEqual(a.union(b), Rect(x: 0, y: 0, width: 15, height: 15))
    }
}

final class FramebufferTests: XCTestCase {
    func pixel(_ fb: GuestFramebuffer, _ x: Int, _ y: Int) -> UInt32 {
        let s = fb.surface!
        s.lock(options: .readOnly, seed: nil); defer { s.unlock(options: .readOnly, seed: nil) }
        return (s.baseAddress + y * s.bytesPerRow + x * 4).load(as: UInt32.self)
    }

    func testAppliesDirtyRect() throws {
        let fb = GuestFramebuffer()
        var data = Data()
        for v: UInt32 in [1, 2, 3, 4] { data.appendLE(v) }
        let r = try fb.apply(FrameUpdate(surfaceWidth: 4, surfaceHeight: 4, x: 1, y: 2, width: 2, height: 2, data: data))
        XCTAssertEqual(r, Rect(x: 1, y: 2, width: 2, height: 2))
        XCTAssertEqual(pixel(fb, 1, 2), 1)
        XCTAssertEqual(pixel(fb, 2, 2), 2)
        XCTAssertEqual(pixel(fb, 1, 3), 3)
        XCTAssertEqual(pixel(fb, 2, 3), 4)
        XCTAssertEqual(pixel(fb, 0, 0), 0)
        XCTAssertEqual(fb.generation, 2)
    }

    func testResizeReallocates() throws {
        let fb = GuestFramebuffer()
        try fb.apply(FrameUpdate(surfaceWidth: 2, surfaceHeight: 2, x: 0, y: 0, width: 1, height: 1, data: Data(count: 4)))
        try fb.apply(FrameUpdate(surfaceWidth: 6, surfaceHeight: 3, x: 0, y: 0, width: 1, height: 1, data: Data(count: 4)))
        XCTAssertEqual(fb.width, 6)
        XCTAssertEqual(fb.height, 3)
    }

    func testLZ4Frames() throws {
        let raw = Data((0..<(16 * 16 * 4)).map { UInt8($0 % 7) })
        var dst = Data(count: raw.count + 1024)
        let n = dst.withUnsafeMutableBytes { d in raw.withUnsafeBytes { s in
            compression_encode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, d.count,
                                      s.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_LZ4_RAW)
        } }
        XCTAssertGreaterThan(n, 0)
        let fb = GuestFramebuffer()
        try fb.apply(FrameUpdate(surfaceWidth: 16, surfaceHeight: 16, x: 0, y: 0, width: 16, height: 16,
                                 encoding: .lz4, data: dst.prefix(n)))
        XCTAssertEqual(pixel(fb, 1, 0), raw.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) })
    }
}

final class GeometryTests: XCTestCase {
    func testOneToOneMapping() {
        let g = CoherenceGeometry(hostScreenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                  display: DisplayInfo(widthPoints: 1512, heightPoints: 982, scale: 2, menuBarHeight: 37))
        let host = g.hostRect(forGuest: Rect(x: 100, y: 50, width: 400, height: 300))
        XCTAssertEqual(host, CGRect(x: 100, y: 982 - 50 - 300, width: 400, height: 300))
        XCTAssertEqual(g.guestRect(forHost: host), Rect(x: 100, y: 50, width: 400, height: 300))
        let p = g.guestPoint(forHost: CGPoint(x: 110, y: 982 - 60))
        XCTAssertEqual(p, CGPoint(x: 110, y: 60))
        XCTAssertEqual(g.contentsRect(forGuest: Rect(x: 756, y: 491, width: 378, height: 491)),
                       CGRect(x: 0.5, y: 0.5, width: 0.25, height: 0.5))
        XCTAssertEqual(g.contentsRect(forGuest: Rect(x: 0, y: 0, width: 1512, height: 491)),
                       CGRect(x: 0, y: 0, width: 1, height: 0.5))
    }

    func testScaledAndOffsetScreen() {
        // Host screen half the size, positioned at x=200 (secondary display).
        let g = CoherenceGeometry(hostScreenFrame: CGRect(x: 200, y: 100, width: 800, height: 500),
                                  display: DisplayInfo(widthPoints: 1600, heightPoints: 1000, scale: 2, menuBarHeight: 24))
        let host = g.hostRect(forGuest: Rect(x: 0, y: 0, width: 1600, height: 1000))
        XCTAssertEqual(host, CGRect(x: 200, y: 100, width: 800, height: 500))
        XCTAssertEqual(g.guestPoint(forHost: CGPoint(x: 600, y: 350)), CGPoint(x: 800, y: 500))
    }
}

final class ChannelTests: XCTestCase {
    func testChannelOverSocketPair() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let a = AgentChannel(fileDescriptor: fds[0]), b = AgentChannel(fileDescriptor: fds[1])
        let q = DispatchQueue(label: "test")
        let got = expectation(description: "messages")
        got.expectedFulfillmentCount = 3
        let closed = expectation(description: "peer closed")
        var received: [AgentMessage] = []
        let lock = NSLock()
        b.start(callbackQueue: q, onMessage: { m in lock.lock(); received.append(m); lock.unlock(); got.fulfill() },
                onClose: { _ in closed.fulfill() })
        a.start(callbackQueue: q, onMessage: { _ in }, onClose: { _ in })
        let big = Data(repeating: 7, count: 1024 * 768 * 4)
        a.send(.ping(9))
        a.send(.frame(FrameUpdate(surfaceWidth: 1024, surfaceHeight: 768, x: 0, y: 0, width: 1024, height: 768, data: big)))
        a.send(.log("done"))
        wait(for: [got], timeout: 5)
        XCTAssertEqual(received.first, .ping(9))
        XCTAssertEqual(received.last, .log("done"))
        if case .frame(let f) = received[1] { XCTAssertEqual(f.data.count, big.count) } else { XCTFail("no frame") }
        a.close()
        wait(for: [closed], timeout: 5)
        XCTAssertFalse(a.send(.ping(1)))
    }

    func testSessionHandshake() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let guest = AgentChannel(fileDescriptor: fds[1])
        guest.start(callbackQueue: .main, onMessage: { m in
            if case .hello = m {
                guest.send(.hello(Hello(role: "guest", os: "macOS test", agentVersion: "t", capabilities: [])))
                guest.send(.windowList(WindowList(windows: [])))
            }
        }, onClose: { _ in })
        let session = AgentSession(channel: AgentChannel(fileDescriptor: fds[0]))
        let ready = expectation(description: "ready")
        let windows = expectation(description: "windows")
        session.onStateChange = { if case .ready(let h) = $0 { XCTAssertEqual(h.os, "macOS test"); ready.fulfill() } }
        session.onWindowsChanged = { _ in windows.fulfill() }
        session.start()
        wait(for: [ready, windows], timeout: 5)
        XCTAssertTrue(session.isReady)
        session.close()
        guest.close()
    }

    func testTypingSendsTextOnlyKeysAndRealReturnAndTab() throws {
        let events = try XCTUnwrap(KeyEvent.typing("é字\n👍🏽\t"))
        XCTAssertEqual(events.count, 10)
        XCTAssertEqual(events.map(\.keyCode), [0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0x24, 0x24, 0xFFFF, 0xFFFF, 0x30, 0x30])
        XCTAssertEqual(events.map(\.down), [true, false, true, false, true, false, true, false, true, false])
        XCTAssertEqual(events.map(\.text), ["é", "é", "字", "字", "\r", "\r", "👍🏽", "👍🏽", "\t", "\t"])
        XCTAssertTrue(events.allSatisfy { $0.modifiers == 0 })
        XCTAssertEqual(KeyEvent.typing("a\r\nb")?.map(\.keyCode), [0xFFFF, 0xFFFF, 0x24, 0x24, 0xFFFF, 0xFFFF])
        XCTAssertEqual(KeyEvent.typing(""), [])
        XCTAssertNil(KeyEvent.typing("bell\u{07}"))
        XCTAssertNil(KeyEvent.typing("esc\u{1B}"))
    }
}
