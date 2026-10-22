import Foundation
import IOSurface
import Compression
import VitrineAgentProtocol

/// Host-side mirror of the guest display, stored in an IOSurface so any number of CALayers can
/// display sub-rectangles of it without copies.
///
/// Threading: pixel work (LZ4 decode + `memcpy` into the surface) runs on the agent's frame queue,
/// not the main thread — a 1080p dirty rect is megabytes per frame and would otherwise stall the UI.
/// The IOSurface is only touched while holding its own lock, so a layer may read it concurrently.
/// `surface`/`width`/`height`/`generation` are `lock`-guarded because the main thread reads them
/// while the frame queue writes them; main-thread code should prefer `snapshot()`.
public final class GuestFramebuffer {
    private let lock = NSLock()
    private var _surface: IOSurface?
    private var _width = 0
    private var _height = 0
    private var _generation: UInt64 = 0
    private var scratch = Data()
    /// Largest decompressed tile accepted (senders split updates into bands well below this).
    static let maxDecodedBytes = AgentProtocol.maxMessageSize

    public init() {}

    /// Surface and geometry in one consistent read. Use this from the main thread: a resize on the
    /// frame queue can replace the surface between two individual property reads.
    public func snapshot() -> (surface: IOSurface?, width: Int, height: Int, generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return (_surface, _width, _height, _generation)
    }

    public var surface: IOSurface? { lock.lock(); defer { lock.unlock() }; return _surface }
    public var width: Int { lock.lock(); defer { lock.unlock() }; return _width }
    public var height: Int { lock.lock(); defer { lock.unlock() }; return _height }
    /// Incremented on every applied update; layers compare it to decide whether to refresh.
    public var generation: UInt64 { lock.lock(); defer { lock.unlock() }; return _generation }

    /// Applies one dirty-rect update. Returns the updated rect in pixels, or nil if it was dropped.
    @discardableResult
    public func apply(_ update: FrameUpdate) throws -> Rect? {
        let sw = Int(update.surfaceWidth), sh = Int(update.surfaceHeight)
        let w = Int(update.width), h = Int(update.height), x = Int(update.x), y = Int(update.y)
        // Validate against the declared surface before allocating anything for it.
        guard w > 0, h > 0, x + w <= sw, y + h <= sh else { return nil }
        if update.encoding == .lz4, w * h * 4 > Self.maxDecodedBytes {
            throw AgentProtocolError.malformed("lz4 tile \(w)x\(h) too large")
        }
        if snapshot().surface == nil || sw != width || sh != height {
            try allocate(width: sw, height: sh)
        }
        guard let surface else { return nil }

        let pixels: Data
        switch update.encoding {
        case .raw:
            pixels = update.data
        case .lz4:
            pixels = try Self.decompressLZ4(update.data, expected: update.decodedByteCount, scratch: &scratch)
        }
        guard pixels.count == w * h * 4 else {
            throw AgentProtocolError.malformed("frame payload \(pixels.count) bytes, expected \(w * h * 4)")
        }

        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        let base = surface.baseAddress
        let stride = surface.bytesPerRow
        let rowBytes = w * 4
        pixels.withUnsafeBytes { src in
            guard let s = src.baseAddress else { return }
            for row in 0..<h {
                memcpy(base + (y + row) * stride + x * 4, s + row * rowBytes, rowBytes)
            }
        }
        lock.lock(); _generation &+= 1; lock.unlock()
        return Rect(x: Double(x), y: Double(y), width: Double(w), height: Double(h))
    }

    /// (Re)allocates the surface when the size changes.
    public func allocateIfNeeded(width: Int, height: Int) throws {
        let s = snapshot()
        if s.surface == nil || width != s.width || height != s.height { try allocate(width: width, height: height) }
    }

    /// Writes tightly packed BGRA rows. `opaque` forces alpha to 255 (VNC sends an undefined pad byte).
    public func write(x: Int, y: Int, width w: Int, height h: Int, pixels: Data, opaque: Bool) throws {
        let s0 = snapshot()
        guard let surface = s0.surface, w > 0, h > 0, x >= 0, y >= 0,
              x + w <= s0.width, y + h <= s0.height, pixels.count >= w * h * 4 else {
            throw AgentProtocolError.malformed("rect \(x),\(y) \(w)x\(h) outside \(s0.width)x\(s0.height)")
        }
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        let base = surface.baseAddress, stride = surface.bytesPerRow, rowBytes = w * 4
        pixels.withUnsafeBytes { src in
            guard let s = src.baseAddress else { return }
            for row in 0..<h {
                let dst = base + (y + row) * stride + x * 4
                memcpy(dst, s + row * rowBytes, rowBytes)
                if opaque {
                    let p = dst.assumingMemoryBound(to: UInt8.self)
                    var i = 3
                    while i < rowBytes { p[i] = 0xFF; i += 4 }
                }
            }
        }
        lock.lock(); _generation &+= 1; lock.unlock()
    }

    /// Copies a rectangle within the surface (VNC CopyRect); handles overlapping regions.
    public func copy(fromX sx: Int, fromY sy: Int, toX dx: Int, toY dy: Int, width w: Int, height h: Int) {
        let s0 = snapshot()
        guard let surface = s0.surface, w > 0, h > 0, sx >= 0, sy >= 0, dx >= 0, dy >= 0,
              sx + w <= s0.width, sy + h <= s0.height, dx + w <= s0.width, dy + h <= s0.height else { return }
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        let base = surface.baseAddress, stride = surface.bytesPerRow, rowBytes = w * 4
        let rows: [Int] = dy > sy ? Array((0..<h).reversed()) : Array(0..<h)
        for r in rows {
            memmove(base + (dy + r) * stride + dx * 4, base + (sy + r) * stride + sx * 4, rowBytes)
        }
        lock.lock(); _generation &+= 1; lock.unlock()
    }

    func allocate(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= AgentProtocol.maxSurfaceDimension, height <= AgentProtocol.maxSurfaceDimension else {
            throw AgentProtocolError.malformed("bad surface size \(width)x\(height)")
        }
        let props: [IOSurfacePropertyKey: Any] = [
            .width: width, .height: height,
            .bytesPerElement: 4,
            .pixelFormat: UInt32(0x42475241), // 'BGRA'
        ]
        guard let s = IOSurface(properties: props) else { throw VitrineAgentHostError.surfaceAllocationFailed }
        // Start fully transparent so unpainted regions don't show garbage.
        s.lock(options: [], seed: nil)
        memset(s.baseAddress, 0, s.allocationSize)
        s.unlock(options: [], seed: nil)
        lock.lock()
        _surface = s
        _width = width
        _height = height
        _generation &+= 1
        lock.unlock()
    }

    static func decompressLZ4(_ data: Data, expected: Int, scratch: inout Data) throws -> Data {
        if scratch.count < expected { scratch = Data(count: expected) }
        let n = scratch.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, expected,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_LZ4_RAW)
            }
        }
        guard n == expected else { throw AgentProtocolError.malformed("lz4 decoded \(n) of \(expected) bytes") }
        return scratch.prefix(expected)
    }
}

public enum VitrineAgentHostError: Error, LocalizedError {
    case surfaceAllocationFailed
    case notConnected
    public var errorDescription: String? {
        switch self {
        case .surfaceAllocationFailed: return "could not allocate the display surface"
        case .notConnected: return "guest agent is not connected"
        }
    }
}
