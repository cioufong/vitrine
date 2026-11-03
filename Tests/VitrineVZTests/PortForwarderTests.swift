import XCTest
import Darwin
@testable import VitrineVZ
@testable import VitrineCore

final class PortForwarderTests: XCTestCase {
    /// A guest that never answers the SYN (its accept queue is full, say) must not keep the flow, and
    /// the Mac-side connection with it, forever: nothing reads the client until the guest side is up,
    /// so a client that has gone away goes unnoticed.
    func testUnansweredGuestConnectionIsDropped() throws {
        let port = Int.random(in: 41000...48000)
        // TEST-NET-1: never routed, so the connection attempt gets no answer.
        let forwarder = PortForwarder(guestAddress: { "192.0.2.1" }, log: { _ in }, guestConnectTimeout: 1)
        forwarder.start([.init(hostAddress: "127.0.0.1", hostPort: port, guestPort: 8080)])
        defer { forwarder.stop() }

        let fd = try connectLoopback(port: port)
        let opened = Date().addingTimeInterval(3)
        while forwarder.flowCount == 0, Date() < opened { usleep(20_000) }
        XCTAssertEqual(forwarder.flowCount, 1, "the forwarder accepted the connection")
        close(fd)

        let deadline = Date().addingTimeInterval(8)
        while forwarder.flowCount > 0, Date() < deadline { usleep(50_000) }
        XCTAssertEqual(forwarder.flowCount, 0, "flow kept after the guest never answered")
    }

    private func connectLoopback(port: Int) throws -> Int32 {
        let deadline = Date().addingTimeInterval(3)
        while true {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            if rc == 0 { return fd }
            close(fd)
            // The listener starts asynchronously.
            guard Date() < deadline else { throw POSIXError(.ECONNREFUSED) }
            usleep(50_000)
        }
    }
}
