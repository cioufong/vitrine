// Dev helper: non-blocking TCP connect probe, same logic as GuestNetwork.tcpReachable.
import Foundation

let host = CommandLine.arguments[1], port = UInt16(CommandLine.arguments[2])!
let fd = socket(AF_INET, SOCK_STREAM, 0)
var addr = sockaddr_in()
addr.sin_family = sa_family_t(AF_INET)
addr.sin_port = port.bigEndian
inet_pton(AF_INET, host, &addr.sin_addr)
let flags = fcntl(fd, F_GETFL)
print("F_GETFL", flags, "set", fcntl(fd, F_SETFL, flags | O_NONBLOCK))
let rc = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
}
let e = errno
print("connect rc", rc, "errno", e, String(cString: strerror(e)))
var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
print("poll", poll(&pfd, 1, 500), "revents", pfd.revents)
var err: Int32 = 0
var len = socklen_t(MemoryLayout<Int32>.size)
getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
print("SO_ERROR", err, String(cString: strerror(err)))
