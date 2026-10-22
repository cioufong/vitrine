import Foundation
import IOSurface
import VitrineCore
import VitrineAgentHost
import VitrineAgentProtocol

/// VNC (RFB 3.8) client for QEMU's display, rendering into a shared IOSurface framebuffer.
///
/// Supports Raw + CopyRect, DesktopSize, and QEMU's extended key event (raw scancodes, so keyboard
/// layouts behave like real hardware). Runs its read loop on a background thread; frame callbacks
/// are delivered on the main queue.
public final class RFBClient: @unchecked Sendable {
    public let framebuffer = GuestFramebuffer()
    public var onFrame: ((Rect) -> Void)?
    public var onResize: ((Int, Int) -> Void)?
    public var onClose: ((Error?) -> Void)?

    /// Guards state shared between the reader thread and the main thread: geometry, the surface
    /// reference (replaced on DesktopSize), extended-key support and the open/closed flags.
    private let state = NSLock()
    private var _width = 0, _height = 0
    private var _supportsExtendedKeys = false
    private var _supportsResize = false
    private var _closed = false
    private var loopRunning = false
    private var fdReleased = false

    public var width: Int { state.lock(); defer { state.unlock() }; return _width }
    public var height: Int { state.lock(); defer { state.unlock() }; return _height }
    /// The server accepts SetDesktopSize (QEMU forwards it to the guest display, e.g. virtio-gpu).
    public var supportsResize: Bool { state.lock(); defer { state.unlock() }; return _supportsResize }
    private var closed: Bool { state.lock(); defer { state.unlock() }; return _closed }
    /// The surface to display (it is reallocated when the guest resolution changes).
    public var currentSurface: IOSurface? { state.lock(); defer { state.unlock() }; return framebuffer.surface }

    private let fd: Int32
    private let writeLock = NSLock()
    private var reader = BufferedReader(fd: -1)

    public init(socketPath: String, timeout: TimeInterval = 15) throws {
        fd = try UnixSocket.connect(path: socketPath, timeout: timeout)
        reader = BufferedReader(fd: fd)
        try handshake()
    }

    deinit { close() }

    /// Stops the connection. The descriptor itself is closed once the reader thread has exited, so
    /// it can't touch a reused fd number.
    public func close() {
        state.lock()
        let was = _closed
        _closed = true
        state.unlock()
        guard !was else { return }
        shutdown(fd, SHUT_RDWR)
        releaseFDIfIdle()
    }

    private func releaseFDIfIdle() {
        state.lock()
        let release = _closed && !loopRunning && !fdReleased
        if release { fdReleased = true }
        state.unlock()
        if release {
            writeLock.lock(); Darwin.close(fd); writeLock.unlock()
        }
    }

    // MARK: Handshake

    private func handshake() throws {
        let version = try reader.read(12)
        guard String(decoding: version, as: UTF8.self).hasPrefix("RFB ") else { throw VitrineError.protocolError("not an RFB server") }
        try send(Data("RFB 003.008\n".utf8))
        let nTypes = Int(try reader.u8())
        guard nTypes > 0 else { throw VitrineError.protocolError("VNC server refused connection") }
        let types = try reader.read(nTypes)
        guard types.contains(1) else { throw VitrineError.protocolError("VNC server requires authentication") }
        try send(Data([1]))                                  // security: None
        guard try reader.u32() == 0 else { throw VitrineError.protocolError("VNC security handshake failed") }
        try send(Data([1]))                                  // ClientInit: shared
        let w0 = Int(try reader.u16()), h0 = Int(try reader.u16())
        state.lock(); _width = w0; _height = h0; state.unlock()
        _ = try reader.read(16)                              // server pixel format (we override)
        let nameLen = Int(try reader.u32()); _ = try reader.read(nameLen)

        // SetPixelFormat: 32bpp, depth 24, little-endian, true colour, BGRA layout (B at shift 0).
        var pf = Data([0, 0, 0, 0])
        pf += [32, 24, 0, 1]                                 // bpp, depth, big-endian=0, true-colour=1
        pf.appendBE(UInt16(255)); pf.appendBE(UInt16(255)); pf.appendBE(UInt16(255))
        pf += [16, 8, 0, 0, 0, 0]                            // red/green/blue shifts + padding
        try send(pf)

        // SetEncodings: Raw, CopyRect, DesktopSize, ExtendedDesktopSize (client-requested resize),
        // QEMU extended key event.
        let encodings: [Int32] = [1, 0, -223, -308, -258]
        var se = Data([2, 0]); se.appendBE(UInt16(encodings.count))
        for e in encodings { se.appendBE(UInt32(bitPattern: e)) }
        try send(se)
        state.lock(); defer { state.unlock() }
        try framebuffer.allocateIfNeeded(width: w0, height: h0)
    }

    /// Starts the update loop.
    public func start() {
        state.lock(); loopRunning = !_closed; let run = loopRunning; state.unlock()
        guard run else { return }
        let t = Thread { [self] in
            loop()
            state.lock(); loopRunning = false; state.unlock()
            releaseFDIfIdle()
        }
        t.name = "vitrine.rfb"
        t.qualityOfService = .userInteractive
        t.start()
    }

    private func loop() {
        do {
            try requestUpdate(incremental: false)
            while !closed {
                let type = try reader.u8()
                switch type {
                case 0: try handleFramebufferUpdate(); try requestUpdate(incremental: true)
                case 1:                                         // colour map (unused for true colour)
                    _ = try reader.read(1); _ = try reader.u16(); let n = Int(try reader.u16()); _ = try reader.read(n * 6)
                case 2: break                                   // bell
                case 3: _ = try reader.read(3); let n = Int(try reader.u32()); _ = try reader.read(n) // cut text
                default: throw VitrineError.protocolError("unknown VNC message \(type)")
                }
            }
        } catch {
            if !closed { DispatchQueue.main.async { self.onClose?(error) } }
            return
        }
        DispatchQueue.main.async { self.onClose?(nil) }
    }

    private func requestUpdate(incremental: Bool) throws {
        var m = Data([3, incremental ? 1 : 0])
        m.appendBE(UInt16(0)); m.appendBE(UInt16(0)); m.appendBE(UInt16(width)); m.appendBE(UInt16(height))
        try send(m)
    }

    private func handleFramebufferUpdate() throws {
        _ = try reader.u8()
        let n = Int(try reader.u16())
        var dirty = Rect(x: 0, y: 0, width: 0, height: 0)
        for _ in 0..<n {
            let x = Int(try reader.u16()), y = Int(try reader.u16())
            let w = Int(try reader.u16()), h = Int(try reader.u16())
            let enc = Int32(bitPattern: try reader.u32())
            switch enc {
            case 0: // Raw
                let pixels = try reader.read(w * h * 4)
                if w > 0 && h > 0 {
                    try framebuffer.write(x: x, y: y, width: w, height: h, pixels: pixels, opaque: true)
                    dirty = dirty.union(Rect(x: Double(x), y: Double(y), width: Double(w), height: Double(h)))
                }
            case 1: // CopyRect
                let sx = Int(try reader.u16()), sy = Int(try reader.u16())
                framebuffer.copy(fromX: sx, fromY: sy, toX: x, toY: y, width: w, height: h)
                dirty = dirty.union(Rect(x: Double(x), y: Double(y), width: Double(w), height: Double(h)))
            case -308: // ExtendedDesktopSize: x = reason, y = status, then the screen layout
                let screens = Int(try reader.u8()); _ = try reader.read(3 + screens * 16)
                state.lock(); _supportsResize = true; state.unlock()
                guard y == 0, w > 0, h > 0 else { break } // status != 0: a resize we asked for was refused
                fallthrough
            case -223: // DesktopSize
                state.lock()
                _width = w; _height = h
                do { try framebuffer.allocateIfNeeded(width: w, height: h) } catch { state.unlock(); throw error }
                state.unlock()
                let (nw, nh) = (w, h)
                DispatchQueue.main.async { self.onResize?(nw, nh) }
                dirty = Rect(x: 0, y: 0, width: Double(w), height: Double(h))
            case -258: // QEMU extended key event support announcement
                state.lock(); _supportsExtendedKeys = true; state.unlock()
            default:
                throw VitrineError.protocolError("unsupported VNC encoding \(enc)")
            }
        }
        if !dirty.isEmpty {
            let d = dirty
            DispatchQueue.main.async { self.onFrame?(d) }
        }
    }

    // MARK: Input

    /// Pointer in framebuffer pixels; buttons bitmask (1 left, 2 middle, 4 right, 8/16 wheel up/down,
    /// 32/64 wheel left/right).
    public func pointer(x: Int, y: Int, buttons: UInt8) {
        var m = Data([5, buttons])
        m.appendBE(UInt16(clamping: max(0, min(x, width - 1)))); m.appendBE(UInt16(clamping: max(0, min(y, height - 1))))
        try? send(m)
    }

    /// Asks the guest display to change resolution (RFB SetDesktopSize). No-op when unsupported.
    public func requestDesktopSize(width: Int, height: Int) {
        guard supportsResize, width > 0, height > 0 else { return }
        var m = Data([251, 0])
        m.appendBE(UInt16(clamping: width)); m.appendBE(UInt16(clamping: height))
        m += [1, 0]                                             // one screen, padding
        m.appendBE(UInt32(0)); m.appendBE(UInt16(0)); m.appendBE(UInt16(0)) // id, x, y
        m.appendBE(UInt16(clamping: width)); m.appendBE(UInt16(clamping: height)); m.appendBE(UInt32(0))
        try? send(m)
    }

    /// Key by macOS virtual key code (converted to an XT scancode) with the keysym as a fallback.
    public func key(macKeyCode: UInt16, down: Bool, keysym: UInt32) {
        state.lock(); let extended = _supportsExtendedKeys; state.unlock()
        if extended, let scancode = XTScancodes.fromMac[macKeyCode] {
            var m = Data([255, 0])
            m.appendBE(UInt16(down ? 1 : 0)); m.appendBE(keysym); m.appendBE(UInt32(scancode))
            try? send(m)
        } else {
            var m = Data([4, down ? 1 : 0, 0, 0]); m.appendBE(keysym)
            try? send(m)
        }
    }

    private func send(_ data: Data) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        guard !closed else { throw VitrineError.io("VNC connection closed") }
        try data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 { if errno == EINTR { continue }; throw VitrineError.io("VNC write failed") }
                off += n
            }
        }
    }
}

/// Blocking buffered reader over a file descriptor.
struct BufferedReader {
    let fd: Int32
    private var buf = [UInt8](repeating: 0, count: 1 << 20)
    private var start = 0, end = 0
    init(fd: Int32) { self.fd = fd }

    mutating func read(_ count: Int) throws -> Data {
        var out = Data(capacity: count)
        var need = count
        while need > 0 {
            if start == end {
                let n = Darwin.read(fd, &buf, buf.count)
                if n <= 0 { if n < 0 && errno == EINTR { continue }; throw VitrineError.io("connection closed") }
                start = 0; end = n
            }
            let take = min(need, end - start)
            out.append(contentsOf: buf[start..<(start + take)])
            start += take; need -= take
        }
        return out
    }
    mutating func u8() throws -> UInt8 { try read(1)[0] }
    mutating func u16() throws -> UInt16 { let d = try read(2); return UInt16(d[d.startIndex]) << 8 | UInt16(d[d.startIndex + 1]) }
    mutating func u32() throws -> UInt32 {
        let d = try read(4)
        return d.reduce(0) { $0 << 8 | UInt32($1) }
    }
}

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ v: T) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }
}
