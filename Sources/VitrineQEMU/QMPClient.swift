import Foundation
import VitrineCore

/// Minimal QEMU Machine Protocol client over a Unix socket (JSON lines).
public final class QMPClient: @unchecked Sendable {
    private let fd: Int32
    private var buffer = Data()
    private let lock = NSLock()
    /// Set after a timeout or I/O error: the reply stream may be out of step, so stop using it.
    private var broken = false

    /// Connects, reads the greeting and negotiates capabilities. Every command must answer within
    /// `commandTimeout`, so a wedged QEMU can't block callers forever.
    public init(socketPath: String, timeout: TimeInterval = 10, commandTimeout: TimeInterval = 15) throws {
        fd = try UnixSocket.connect(path: socketPath, timeout: timeout)
        var tv = timeval(tv_sec: Int(commandTimeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = try readJSON()                         // {"QMP": {...}} greeting
        _ = try execute("qmp_capabilities")
    }

    deinit { close(fd) }

    /// Runs a command and returns its "return" value. Asynchronous events are skipped.
    @discardableResult
    public func execute(_ command: String, arguments: [String: Any]? = nil) throws -> Any? {
        lock.lock(); defer { lock.unlock() }
        guard !broken else { throw VitrineError.io("QMP connection unusable after an earlier error") }
        do { return try executeLocked(command, arguments: arguments) } catch let e as VitrineError {
            if case .io = e { broken = true }
            throw e
        }
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
