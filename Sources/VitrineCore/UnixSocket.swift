import Foundation

/// Blocking Unix-domain socket helpers for every socket Vitrine opens: control and serial console
/// sockets, QEMU's QMP/VNC/agent sockets, and the network and bridge sockets. Paths are limited to
/// 104 bytes (`sun_path`).
public enum UnixSocket {
    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw VitrineError.io("socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        return addr
    }

    private static func withAddress(_ addr: sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        var addr = addr
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    private static func newSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VitrineError.io("socket: \(String(cString: strerror(errno)))") }
        return fd
    }

    /// A listening socket at `path` (an old socket file there is replaced). With `mode` (0o600:
    /// only this user may connect) the socket's permissions are set before it accepts anyone.
    public static func listen(path: String, mode: mode_t? = nil, backlog: Int32 = 8) throws -> Int32 {
        let addr = try address(path)
        unlink(path)
        let fd = try newSocket()
        guard withAddress(addr, { bind(fd, $0, $1) }) == 0, mode.map({ chmod(path, $0) == 0 }) ?? true,
              Darwin.listen(fd, backlog) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw VitrineError.io("cannot listen on \(path): \(message)")
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    /// Connects to the socket at `path`. With a `timeout`, retries until the socket accepts (QEMU
    /// creates its sockets shortly after launch). Writes to the result never raise SIGPIPE.
    public static func connect(path: String, timeout: TimeInterval? = nil) throws -> Int32 {
        let addr = try address(path)
        let deadline = Date().addingTimeInterval(timeout ?? 0)
        while true {
            let fd = try newSocket()
            if withAddress(addr, { Darwin.connect(fd, $0, $1) }) == 0 {
                var on: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                return fd
            }
            let message = String(cString: strerror(errno))
            close(fd)
            guard timeout != nil else { throw VitrineError.io("cannot connect to \(path): \(message)") }
            if Date() > deadline { throw VitrineError.io("could not connect to \(path)") }
            usleep(100_000)
        }
    }

    /// A connected datagram pair with buffers sized for network traffic (the defaults hold two frames).
    public static func datagramPair() throws -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            throw VitrineError.io("socketpair: \(String(cString: strerror(errno)))")
        }
        for fd in fds { setBufferSizes(fd, send: 1 << 20, receive: 4 << 20) }
        return (fds[0], fds[1])
    }

    /// Larger stream buffers for network traffic: the defaults (8 KB) hold five frames.
    public static func enlargeBuffers(_ fd: Int32) {
        setBufferSizes(fd, send: 1 << 20, receive: 1 << 20)
    }

    public static func setBufferSizes(_ fd: Int32, send: Int32, receive: Int32) {
        var snd = send, rcv = receive
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &snd, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Writes all of `data` (blocking). False on an error, including a send timeout.
    @discardableResult
    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 { if errno == EINTR { continue }; return false }
                offset += n
            }
            return true
        }
    }

    public enum ReadError: Error { case timedOut, failed, tooLong }

    /// Reads up to the first newline (at most `limit` bytes); anything after it is dropped.
    /// nil = closed before a full line.
    public static func readLine(_ fd: Int32, limit: Int) throws -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.count < limit {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw errno == EAGAIN ? ReadError.timedOut : ReadError.failed
            }
            if n == 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
            if let nl = buffer.firstIndex(of: 0x0A) { return buffer[buffer.startIndex..<nl] }
        }
        throw ReadError.tooLong
    }
}
