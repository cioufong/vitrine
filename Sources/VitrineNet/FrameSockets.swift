import Foundation

/// Ethernet frames over a socket. `.stream` is the length-prefixed framing of QEMU's
/// `-netdev stream` and socket_vmnet (each frame preceded by its length as a 4-byte big-endian
/// integer); `.datagram` is one frame per datagram (Virtualization.framework's file-handle attachment).
public final class FrameSocket: @unchecked Sendable {
    public enum Framing: Sendable { case stream, datagram }

    public let fd: Int32
    public let framing: Framing
    private let writeLock = NSLock()
    private var source: DispatchSourceRead?
    private var closed = false
    private let stateLock = NSLock()

    /// Largest frame accepted (jumbo frames included); a stream announcing more is broken.
    public static let maxFrame = 65_550

    /// Takes ownership of `fd`.
    public init(fd: Int32, framing: Framing) {
        self.fd = fd
        self.framing = framing
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Reads frames on `queue` until the peer closes or `close` is called, then calls `onClose` once.
    public func onFrames(queue: DispatchQueue, _ handler: @escaping (UnsafeRawBufferPointer) -> Void,
                         onClose: @escaping () -> Void) {
        stateLock.lock()
        guard !closed else {
            // Closed before the reader started: the descriptor is already gone (and may be reused).
            stateLock.unlock()
            onClose()
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        self.source = source
        stateLock.unlock()
        let capacity = framing == .stream ? 256 << 10 : Self.maxFrame
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        var filled = 0
        var ended = false
        let end = { [weak self] in
            guard !ended else { return }
            ended = true
            self?.close()
            onClose()
        }
        source.setEventHandler { [fd, framing] in
            let n = read(fd, buffer + filled, capacity - filled)
            if n <= 0 {
                if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
                end()
                return
            }
            if framing == .datagram {
                handler(UnsafeRawBufferPointer(start: buffer, count: n))
                return
            }
            filled += n
            var offset = 0
            while filled - offset >= 4 {
                let p = buffer + offset
                let len = Int(p.load(fromByteOffset: 0, as: UInt8.self)) << 24 | Int(p.load(fromByteOffset: 1, as: UInt8.self)) << 16
                    | Int(p.load(fromByteOffset: 2, as: UInt8.self)) << 8 | Int(p.load(fromByteOffset: 3, as: UInt8.self))
                guard len <= Self.maxFrame else { end(); return }
                guard filled - offset - 4 >= len else { break }
                if len > 0 { handler(UnsafeRawBufferPointer(start: p + 4, count: len)) }
                offset += 4 + len
            }
            if offset > 0 {
                memmove(buffer, buffer + offset, filled - offset)
                filled -= offset
            }
        }
        // The source owns the buffer and, once installed, the descriptor.
        source.setCancelHandler { [fd] in
            buffer.deallocate()
            Darwin.close(fd)
        }
        source.resume()
    }

    /// Sends one frame; returns false once the socket is unusable. Blocks while the peer's buffer is full.
    @discardableResult
    public func write(_ frame: UnsafeRawBufferPointer) -> Bool {
        guard frame.count > 0, frame.count <= Self.maxFrame, let base = frame.baseAddress else { return true }
        writeLock.lock(); defer { writeLock.unlock() }
        if framing == .datagram {
            while true {
                let n = send(fd, base, frame.count, 0)
                if n >= 0 { return true }
                // A full datagram socket buffer drops the frame, like a busy switch would.
                if errno == ENOBUFS || errno == EAGAIN { return true }
                if errno != EINTR { return false }
            }
        }
        var header = UInt32(frame.count).bigEndian
        return withUnsafeMutableBytes(of: &header) { h in
            writeAll([iovec(iov_base: h.baseAddress, iov_len: 4),
                      iovec(iov_base: UnsafeMutableRawPointer(mutating: base), iov_len: frame.count)])
        }
    }

    /// writev until every byte of `iov` is out; the caller keeps the buffers alive.
    private func writeAll(_ iovs: [iovec]) -> Bool {
        var iov = iovs
        var remaining = iov.reduce(0) { $0 + $1.iov_len }
        while remaining > 0 {
            let n = iov.withUnsafeMutableBufferPointer { writev(fd, $0.baseAddress, Int32($0.count)) }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return false
            }
            remaining -= n
            // Advance past what was written.
            var skip = n
            while skip > 0, !iov.isEmpty {
                if skip >= iov[0].iov_len { skip -= iov[0].iov_len; iov.removeFirst() } else {
                    iov[0].iov_base += skip
                    iov[0].iov_len -= skip
                    skip = 0
                }
            }
        }
        return true
    }

    public func close() {
        stateLock.lock()
        if closed { stateLock.unlock(); return }
        closed = true
        let source = self.source
        stateLock.unlock()
        if let source {
            source.cancel()  // its cancel handler frees the buffer and closes the descriptor
        } else {
            Darwin.close(fd)
        }
    }
}
