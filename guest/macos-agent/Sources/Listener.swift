import Foundation
import Darwin

/// Accepts stream connections on AF_VSOCK (production) or a Unix socket (development/tests).
final class Listener {
    enum Endpoint {
        case vsock(port: UInt32)
        case unix(path: String)
    }

    private let endpoint: Endpoint
    private var fd: Int32 = -1

    init(_ endpoint: Endpoint) { self.endpoint = endpoint }

    /// sockaddr_vm from <sys/vsock.h> (packed, 12 bytes).
    private struct SockaddrVM {
        var svm_len: UInt8
        var svm_family: UInt8
        var svm_reserved1: UInt16
        var svm_port: UInt32
        var svm_cid: UInt32
    }
    private static let AF_VSOCK: Int32 = 40
    private static let VMADDR_CID_ANY: UInt32 = 0xFFFF_FFFF

    func open() throws {
        switch endpoint {
        case .vsock(let port):
            fd = socket(Self.AF_VSOCK, SOCK_STREAM, 0)
            guard fd >= 0 else { throw posixError("socket(AF_VSOCK)") }
            var addr = SockaddrVM(svm_len: UInt8(MemoryLayout<SockaddrVM>.size), svm_family: UInt8(Self.AF_VSOCK),
                                  svm_reserved1: 0, svm_port: port, svm_cid: Self.VMADDR_CID_ANY)
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<SockaddrVM>.size))
                }
            }
            guard rc == 0 else { throw posixError("bind(vsock port \(port))") }
        case .unix(let path):
            unlink(path)
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw posixError("socket(AF_UNIX)") }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw AgentError("socket path too long") }
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                for (i, b) in bytes.enumerated() { buf[i] = b }
            }
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard rc == 0 else { throw posixError("bind(\(path))") }
        }
        guard listen(fd, 4) == 0 else { throw posixError("listen") }
    }

    /// Blocks until a client connects; returns its descriptor.
    func accept() throws -> Int32 {
        while true {
            let c = Darwin.accept(fd, nil, nil)
            if c >= 0 { return c }
            if errno == EINTR { continue }
            throw posixError("accept")
        }
    }
}

struct AgentError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

func posixError(_ what: String) -> AgentError {
    AgentError("\(what): \(String(cString: strerror(errno)))")
}
