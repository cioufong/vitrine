import XCTest
@testable import VitrineQEMU
@testable import VitrineCore

final class NetworkOptionsTests: XCTestCase {
    let env = QEMUEnvironment(binDirectory: URL(fileURLWithPath: "/opt/homebrew/bin"),
                              shareDirectory: URL(fileURLWithPath: "/opt/homebrew/share/qemu"))
    let sockets = QEMUSockets(directory: URL(fileURLWithPath: "/tmp/s"))
    let bundle = VMBundle(url: URL(fileURLWithPath: "/tmp/vm.vitrinevm"))

    private func config() -> VMConfig {
        var c = VMConfig(name: "n", guestOS: .linux, cpuCount: 2, memoryMiB: 2048)
        c.backend = .qemu
        c.disks = [.init(path: "disk.img")]
        return c
    }

    private func netdev(_ c: VMConfig) -> String? {
        let a = QEMUArguments.build(config: c, bundle: bundle, env: env, sockets: sockets, options: .init(withTPM: false))
        return a.firstIndex(of: "-netdev").map { a[$0 + 1] }
    }

    func testPortForwardSpecs() {
        XCTAssertEqual(VMConfig.PortForward(spec: "8080:80"), .init(hostPort: 8080, guestPort: 80))
        XCTAssertEqual(VMConfig.PortForward(spec: "0.0.0.0:2222:22"), .init(hostAddress: "0.0.0.0", hostPort: 2222, guestPort: 22))
        XCTAssertEqual(VMConfig.PortForward(spec: "udp:5353:53"), .init(proto: .udp, hostPort: 5353, guestPort: 53))
        XCTAssertNil(VMConfig.PortForward(spec: "80"))
        XCTAssertNil(VMConfig.PortForward(spec: "a:b"))
        XCTAssertEqual(VMConfig.PortForward(spec: "udp:0.0.0.0:1:2")?.spec, "udp:0.0.0.0:1:2")
    }

    func testForwardsAndHostOnlyOnQEMU() {
        var c = config()
        c.network.portForwards = [.init(hostPort: 8080, guestPort: 80), .init(proto: .udp, hostAddress: "0.0.0.0", hostPort: 5353, guestPort: 53)]
        let nat = netdev(c)!
        XCTAssertTrue(nat.contains(",hostfwd=tcp:127.0.0.1:8080-:80,hostfwd=udp:0.0.0.0:5353-:53"))
        XCTAssertFalse(nat.contains("restrict"))
        c.network.mode = .hostOnly
        XCTAssertTrue(netdev(c)!.hasPrefix("user,id=net0,restrict=on"))
        c.network.mode = .none
        XCTAssertNil(netdev(c))
    }

    func testVmnetAndBridgedNetdev() {
        var c = config()
        c.network.mode = .network
        c.network.networkName = "lab"
        c.network.portForwards = [.init(hostPort: 8080, guestPort: 80)]
        var o = QEMUArguments.Options(withTPM: false, sshPort: 2222)
        o.netdev = "stream,server=off,addr.type=unix,addr.path=/tmp/s/net.sock"
        let a = QEMUArguments.build(config: c, bundle: bundle, env: env, sockets: sockets, options: o)
        let i = try! XCTUnwrap(a.firstIndex(of: "-netdev"))
        XCTAssertEqual(a[i + 1], "stream,server=off,addr.type=unix,addr.path=/tmp/s/net.sock,id=net0")
        XCTAssertTrue(a[i + 3].hasSuffix("netdev=net0,mac=\(c.network.macAddress)"))
        XCTAssertFalse(a.joined(separator: " ").contains("hostfwd"), "forwards are relayed on the Mac instead")
    }

    func testValidation() {
        var c = config()
        c.network.portForwards = [.init(hostPort: 8080, guestPort: 80), .init(hostPort: 8080, guestPort: 81)]
        XCTAssertThrowsError(try c.validate(), "same host port twice")
        c.network.portForwards = [.init(hostPort: 0, guestPort: 80)]
        XCTAssertThrowsError(try c.validate())
        c.network.portForwards = [.init(proto: .udp, hostPort: 5353, guestPort: 53)]
        XCTAssertNoThrow(try c.validate())
        c.backend = .vz
        XCTAssertNoThrow(try c.validate(), "VZ relays UDP too")
        c.network.mode = .network
        XCTAssertThrowsError(try c.validate(), "a named network needs a name")
        c.network.networkName = "lab"
        XCTAssertNoThrow(try c.validate())
        c.network.fixedIPv4 = "192.168.1"
        XCTAssertThrowsError(try c.validate(), "bad fixed address")
        c.network.fixedIPv4 = nil
        c.network.mode = .bridged
        XCTAssertThrowsError(try c.validate(), "bridging needs an interface")
        c.network.bridgeInterface = "en0"
        XCTAssertNoThrow(try c.validate())
        c.network.mode = .nat
        c.network.portForwards = [.init(hostPort: 8080, guestPort: 80)]
        c.network.mode = .none
        XCTAssertThrowsError(try c.validate(), "forwards need an adapter")
    }

    func testOlderConfigsDecode() throws {
        let n = try JSONDecoder().decode(VMConfig.NetworkConfig.self, from: Data(#"{"mode":"nat","macAddress":"02:00:00:00:00:01"}"#.utf8))
        XCTAssertEqual(n.mode, .nat)
        XCTAssertEqual(n.portForwards, [])
        XCTAssertEqual(n.macAddress, "02:00:00:00:00:01")
    }
}
