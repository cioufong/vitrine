import Foundation

/// Bidirectional message channel over a connected stream file descriptor (vsock or Unix socket).
///
/// Reads run on a dedicated thread; writes are serialized on a private queue. `pendingSendBytes`
/// lets producers (the frame streamer) apply back-pressure instead of growing an unbounded queue.
public final class AgentChannel: @unchecked Sendable {
    public typealias MessageHandler = (AgentMessage) -> Void
    public typealias CloseHandler = (Error?) -> Void

    private let fd: Int32
    private let ownsDescriptor: Bool
    private let writeQueue = DispatchQueue(label: "vitrine.agent.write")
    private let lock = NSLock()
    private var _pending = 0
    private var _closed = false
    private var onClose: CloseHandler?
    /// The descriptor is released only once the reader can no longer touch it (avoids fd reuse races).
    private var readerRunning = false
    private var descriptorReleased = false
    /// Messages read but not yet handled. The reader stalls above the limit so a peer that floods
    /// the socket can't grow the callback queue without bound.
    private let undelivered = NSCondition()
    private var undeliveredBytes = 0
    public static let maxUndeliveredBytes = 128 << 20

    public init(fileDescriptor: Int32, ownsDescriptor: Bool = true) {
        self.fd = fileDescriptor
        self.ownsDescriptor = ownsDescriptor
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close() }

    public var pendingSendBytes: Int { lock.lock(); defer { lock.unlock() }; return _pending }
    public var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return _closed }

    /// Starts the read loop. Handlers are invoked on `callbackQueue`.
    public func start(callbackQueue: DispatchQueue = .main, onMessage: @escaping MessageHandler,
                      onClose: @escaping CloseHandler) {
        lock.lock(); self.onClose = onClose; readerRunning = !_closed; let run = readerRunning; lock.unlock()
        guard run else { return }
        let thread = Thread { [self] in
            readLoop(callbackQueue: callbackQueue, onMessage: onMessage)
            lock.lock(); readerRunning = false; lock.unlock()
            releaseDescriptorIfIdle()
        }
        thread.name = "vitrine.agent.read"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func readLoop(callbackQueue: DispatchQueue, onMessage: @escaping MessageHandler) {
        var deframer = MessageDeframer()
        let bufSize = 1 << 20
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
        defer { buf.deallocate() }
        while true {
            let n = read(fd, buf, bufSize)
            if n == 0 { finish(nil, callbackQueue: callbackQueue); return }
            if n < 0 {
                if errno == EINTR { continue }
                finish(isClosed ? nil : VitrineChannelError.io(errno), callbackQueue: callbackQueue); return
            }
            deframer.append(Data(bytes: buf, count: n))
            do {
                while let msg = try deframer.next() {
                    // Whatever the guest sent counts — decoded size never far exceeds wire size, and
                    // no message type (Hello, ones the host ignores) slips past the limit.
                    let cost = max(msg.approximateSize, deframer.lastMessageSize)
                    undelivered.lock()
                    while undeliveredBytes > 0, undeliveredBytes + cost > Self.maxUndeliveredBytes, !isClosed {
                        undelivered.wait(until: Date().addingTimeInterval(0.25))
                    }
                    undeliveredBytes += cost
                    undelivered.unlock()
                    if isClosed { return }
                    callbackQueue.async { [self] in
                        undelivered.lock(); undeliveredBytes -= cost; undelivered.signal(); undelivered.unlock()
                        if !isClosed { onMessage(msg) }
                    }
                }
            } catch {
                finish(error, callbackQueue: callbackQueue); return
            }
        }
    }

    private func finish(_ error: Error?, callbackQueue: DispatchQueue) {
        lock.lock()
        let handler = onClose
        onClose = nil
        lock.unlock()
        close()
        if let handler { callbackQueue.async { handler(error) } }
    }

    /// Queues a message. Returns false if the channel is closed or encoding failed.
    @discardableResult
    public func send(_ message: AgentMessage) -> Bool {
        guard !isClosed, let data = try? AgentCodec.encode(message) else { return false }
        lock.lock(); _pending += data.count; lock.unlock()
        writeQueue.async { [self] in
            defer { lock.lock(); _pending -= data.count; lock.unlock() }
            if isClosed { return }
            data.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = write(fd, raw.baseAddress! + off, raw.count - off)
                    if n < 0 {
                        if errno == EINTR || errno == EAGAIN { continue }
                        shutdown(fd, SHUT_RDWR)  // wakes the reader, which reports the close
                        return
                    }
                    off += n
                }
            }
        }
        return true
    }

    public func close() {
        lock.lock()
        let wasClosed = _closed
        _closed = true
        lock.unlock()
        guard !wasClosed else { return }
        shutdown(fd, SHUT_RDWR)
        undelivered.lock(); undelivered.broadcast(); undelivered.unlock()
        releaseDescriptorIfIdle()
    }

    /// Closes the fd after the channel is closed and the reader thread has exited. Queued on the
    /// write queue so it also runs after any write already in flight.
    private func releaseDescriptorIfIdle() {
        lock.lock()
        let release = _closed && !readerRunning && !descriptorReleased && ownsDescriptor
        if release { descriptorReleased = true }
        lock.unlock()
        if release { writeQueue.async { [fd] in Darwin.close(fd) } }
    }
}

public enum VitrineChannelError: Error, LocalizedError {
    case io(Int32)
    public var errorDescription: String? {
        switch self { case .io(let e): return "agent channel I/O error: \(String(cString: strerror(e)))" }
    }
}
