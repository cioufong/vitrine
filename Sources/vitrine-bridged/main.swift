import Foundation
import vmnet
import VitrineCore
import VitrineNet

// vitrine-bridged: serves bridged networking to one user's VMs.
//
// Bridging a VM onto a Mac interface (vmnet bridged mode) needs root, so this small daemon runs as
// a LaunchDaemon and listens on /var/run/vitrine/bridged.<interface> for every interface macOS can
// bridge, each socket owned by the installing user (mode 0600). Every connection gets its own vmnet
// interface, so each VM appears on the LAN with its own MAC address. Frames use QEMU's
// `-netdev stream` framing (4-byte big-endian length, then the frame); nothing else is parsed.
//
//   vitrine-bridged --user <uid> [--dir /var/run/vitrine]
//   vitrine-bridged --serve-shared <socket>   (testing, unprivileged: a vmnet shared network, macOS 26)

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func log(_ s: String) { print("vitrine-bridged: \(s)") }

/// At most this many VMs per socket, so a misbehaving client can't exhaust vmnet interfaces.
let maxClients = 16

final class Server {
    let path: String
    let makePort: () throws -> VmnetPort
    private var source: DispatchSourceRead?
    private var clients = 0
    private let queue: DispatchQueue

    init(path: String, owner: uid_t?, makePort: @escaping () throws -> VmnetPort) throws {
        self.path = path
        self.makePort = makePort
        queue = DispatchQueue(label: "vitrine-bridged.\((path as NSString).lastPathComponent)")
        let fd = try UnixSocket.listen(path: path)
        if let owner {
            guard chown(path, owner, 0) == 0, chmod(path, 0o600) == 0 else {
                close(fd)
                unlink(path)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                              userInfo: [NSLocalizedDescriptionKey: "cannot hand \(path) to uid \(owner)"])
            }
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            let conn = accept(fd, nil, nil)
            guard conn >= 0 else { return }
            guard let self else { close(conn); return }
            self.serve(conn)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        log("listening on \(path)")
    }

    private func serve(_ conn: Int32) {
        guard clients < maxClients else { close(conn); return }
        let port: VmnetPort
        do { port = try makePort() } catch {
            log("\(path): \(error.localizedDescription)")
            close(conn)
            return
        }
        clients += 1
        UnixSocket.enlargeBuffers(conn)
        let socket = FrameSocket(fd: conn, framing: .stream)
        port.onFrames { socket.write($0) }
        socket.onFrames(queue: DispatchQueue(label: "vitrine-bridged.client"), { port.write($0) }, onClose: { [weak self] in
            port.stop()
            self?.queue.async { self?.clients -= 1 }
        })
    }

    func stop() {
        source?.cancel()
        unlink(path)
    }
}

if let path = option("--serve-shared") {
    guard #available(macOS 26, *) else { log("--serve-shared needs macOS 26"); exit(2) }
    var status = vmnet_return_t.VMNET_SUCCESS
    guard let cfg = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &status),
          let network = vmnet_network_create(cfg, &status) else {
        log("cannot create a shared network (vmnet status \(status.rawValue))")
        exit(1)
    }
    do {
        let server = try Server(path: path, owner: nil) { try VmnetPort.start(on: network) }
        withExtendedLifetime(server) { dispatchMain() }
    } catch {
        log(error.localizedDescription)
        exit(1)
    }
}

guard let uidText = option("--user"), let owner = uid_t(uidText), owner != 0 else {
    log("usage: vitrine-bridged --user <uid> [--dir /var/run/vitrine]")
    exit(2)
}
guard getuid() == 0 else { log("must run as root (it is installed as a LaunchDaemon)"); exit(1) }
let dir = option("--dir") ?? "/var/run/vitrine"
mkdir(dir, 0o755)
chmod(dir, 0o755)

var servers: [String: Server] = [:]
/// Follows the interfaces macOS can bridge (USB/Thunderbolt adapters come and go).
func refresh() {
    let wanted = Set(VmnetInterfaces.bridgeable().filter { !$0.isEmpty && !$0.contains("/") && $0.count < 16 })
    for (name, server) in servers where !wanted.contains(name) {
        server.stop()
        servers[name] = nil
        log("\(name) is gone")
    }
    for name in wanted where servers[name] == nil {
        do {
            servers[name] = try Server(path: "\(dir)/bridged.\(name)", owner: owner) {
                try VmnetPort.startClassic(mode: .VMNET_BRIDGED_MODE, bridging: name)
            }
        } catch {
            log("\(name): \(error.localizedDescription)")
        }
    }
}
refresh()
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + 15, repeating: 15)
timer.setEventHandler { refresh() }
timer.resume()
signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler {
    servers.values.forEach { $0.stop() }
    exit(0)
}
term.resume()
withExtendedLifetime((timer, term)) { dispatchMain() }
