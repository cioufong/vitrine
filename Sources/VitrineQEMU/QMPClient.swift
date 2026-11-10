import Foundation
import VitrineCore

/// Minimal QEMU Machine Protocol client over a Unix socket (JSON lines).
public final class QMPClient: @unchecked Sendable {
    private let socketPath: String
    private let commandTimeout: TimeInterval
    private var fd: Int32 = -1
    private var buffer = Data()
    private let lock = NSLock()
    /// Set after a timeout or I/O error: the reply stream may be out of step, so the connection is
    /// replaced before the next command.
    private var broken = false

    /// Called after the connection was replaced, with QEMU's run state then ("running", "paused",
    /// ...; nil if it couldn't be read). A command that timed out may still have taken effect (a
    /// late `stop` or `cont`), so the owner's idea of the VM's state may be stale. Called on the
    /// calling thread, outside the client's lock, before the command that triggered the reconnect.
    public var onReconnect: ((String?) -> Void)?

    /// Connects, reads the greeting and negotiates capabilities. Every command must answer within
    /// `commandTimeout`, so a wedged QEMU can't block callers forever.
    public init(socketPath: String, timeout: TimeInterval = 10, commandTimeout: TimeInterval = 15) throws {
        self.socketPath = socketPath
        self.commandTimeout = commandTimeout
        fd = try UnixSocket.connect(path: socketPath, timeout: timeout)
        do { try handshakeLocked(timeout: commandTimeout) } catch {
            close(fd)
            fd = -1
            throw error
        }
    }

    deinit { if fd >= 0 { close(fd) } }

    /// Runs a command and returns its "return" value. Asynchronous events are skipped.
    @discardableResult
    public func execute(_ command: String, arguments: [String: Any]? = nil) throws -> Any? {
        // The owner hears about a reconnect before this command runs, so the state it is given
        // isn't already outdated by this command (a `stop` or `cont`).
        if let status = try reconnectIfBroken() { onReconnect?(status) }
        lock.lock(); defer { lock.unlock() }
        // Broken again by another caller in between: the next command reconnects.
        guard !broken else { throw VitrineError.io("QMP connection unusable after an earlier error") }
        do { return try executeLocked(command, arguments: arguments) } catch let e as VitrineError {
            if case .io = e { broken = true }
            throw e
        }
    }

    /// nil when the connection was fine; else the run state read on the new connection.
    private func reconnectIfBroken() throws -> String?? {
        lock.lock(); defer { lock.unlock() }
        guard broken else { return nil }
        return .some(try reconnectLocked())
    }

    /// The socket is server=on,wait=off: QEMU takes a new client once the old one hangs up. The
    /// command that failed is not sent again (`stop`, `migrate` or `device_add` aren't idempotent);
    /// its late reply goes away with the old connection. Stays broken unless the new connection
    /// answered everything in step.
    private func reconnectLocked() throws -> String? {
        if fd >= 0 { close(fd) }
        fd = -1
        buffer.removeAll()
        // One attempt: a QEMU that has exited refuses at once, so polling and shutdown paths fail
        // as quickly as they did before. A live but busy one gets a short deadline.
        do {
            fd = try UnixSocket.connect(path: socketPath)
            try handshakeLocked(timeout: min(commandTimeout, 3))
            setTimeouts(min(commandTimeout, 3))
            let r = try executeLocked("query-status", arguments: nil) as? [String: Any]
            setTimeouts(commandTimeout)
            broken = false
            return r?["status"] as? String
        } catch {
            if fd >= 0 { close(fd) }
            fd = -1
            buffer.removeAll()
            throw VitrineError.io("QMP connection unusable after an earlier error; reconnecting failed: \(error.localizedDescription)")
        }
    }

    /// Greeting and capability negotiation, with `timeout` for each, then `commandTimeout` for commands.
    private func handshakeLocked(timeout: TimeInterval) throws {
        setTimeouts(timeout)
        _ = try readJSON()                         // {"QMP": {...}} greeting
        _ = try executeLocked("qmp_capabilities", arguments: nil)
        setTimeouts(commandTimeout)
    }

    private func setTimeouts(_ seconds: TimeInterval) {
        let whole = Int(seconds)
        var tv = timeval(tv_sec: whole, tv_usec: Int32((seconds - TimeInterval(whole)) * 1_000_000))
        if tv.tv_sec == 0 && tv.tv_usec == 0 { tv.tv_usec = 1 } // zero would mean "no timeout"
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func executeLocked(_ command: String, arguments: [String: Any]?) throws -> Any? {
        var msg: [String: Any] = ["execute": command]
        if let arguments { msg["arguments"] = arguments }
        var data = try JSONSerialization.data(withJSONObject: msg)
        data.append(0x0A)
        guard UnixSocket.writeAll(fd, data) else { throw VitrineError.io("QMP write failed") }
        while true {
            let reply = try readJSON()
            if reply["event"] != nil { continue }
            if let err = reply["error"] as? [String: Any] {
                throw VitrineError.backend("QMP \(command): \(err["desc"] as? String ?? "error")")
            }
            return reply["return"]
        }
    }

    public func status() throws -> String {
        let r = try execute("query-status") as? [String: Any]
        return r?["status"] as? String ?? "unknown"
    }

    private func readJSON() throws -> [String: Any] {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if line.isEmpty { continue }
                guard let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                return obj
            }
            var tmp = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { throw VitrineError.io("QMP command timed out") }
                throw VitrineError.io("QMP connection closed")
            }
            buffer.append(contentsOf: tmp[0..<n])
        }
    }
}
