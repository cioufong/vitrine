import Foundation
import Virtualization
import vmnet
import VitrineCore
import VitrineNet

/// What a running VM's network adapter is plugged into besides the default NAT: a vmnet network
/// (host-only or named) or a bridge to a Mac interface. Open before the VM starts; close after it stops.
///
/// - VZ on a vmnet network: `VZVmnetNetworkDeviceAttachment` on the joined network.
/// - VZ bridged: a datagram socket pair (`VZFileHandleNetworkDeviceAttachment`) relayed to the bridge socket.
/// - QEMU on a vmnet network: `-netdev stream` to a socket here, relayed to a vmnet interface.
/// - QEMU bridged: `-netdev stream` to a socket here, relayed to the bridge socket.
/// QEMU host-only stays on user networking with `restrict=on`. Where frames pass through here, a
/// `GuestAddressWatcher` learns the guest's address from them.
final class NetworkLink: @unchecked Sendable {
    private(set) var vzAttachment: VZNetworkDeviceAttachment?
    private(set) var qemuNetdev: String?
    /// For the VM log.
    let summary: String
    /// The guest's address seen in its frames, on links relayed here.
    private(set) var guestAddress: GuestAddressWatcher?

    private var lease: VmnetNetworks.Lease?
    private var port: VmnetPort?
    private var sockets: [FrameSocket] = []
    /// QEMU bridged through a helper socket: the connection to it.
    private var bridge: FrameSocket?
    private var listener: DispatchSourceRead?
    private var listenPath: String?
    private let queue = DispatchQueue(label: "vitrine.network-link")
    private let lock = NSLock()
    private var closed = false

    private init(summary: String) { self.summary = summary }

    /// nil when the VM uses the default NAT (or QEMU's user networking).
    static func open(bundle: VMBundle, config: VMConfig, qemu: Bool) throws -> NetworkLink? {
        guard config.network.isConnected else { return nil }
        switch config.network.mode {
        case .nat, .none:
            return nil
        case .hostOnly where qemu:
            return nil
        case .hostOnly, .network:
            guard #available(macOS 26, *) else {
                throw VitrineError.unsupported("\(config.network.mode == .hostOnly ? "host-only" : "named") networks need macOS 26 or later; choose Shared Network (NAT)")
            }
            let (network, lease) = try VmnetNetworks.acquire(for: config)
            let link = NetworkLink(summary: NetworkOwner.display(lease.key))
            link.lease = lease
            do {
                if qemu {
                    let port = try VmnetPort.start(on: network)
                    link.port = port
                    link.watchGuest(bundle: bundle, config: config)
                    try link.serveQEMU(bundle: bundle, port: port)
                } else {
                    link.vzAttachment = VZVmnetNetworkDeviceAttachment(network: network)
                }
            } catch {
                link.close()
                throw error
            }
            return link
        case .bridged:
            guard let interface = config.network.bridgeInterface, !interface.isEmpty else {
                throw VitrineError.invalidConfig("choose a Mac interface to bridge \(config.name) to (Configuration › Hardware › Network)")
            }
            if Entitlement.vmNetworking.isGranted {
                return try openNativeBridge(interface: interface, bundle: bundle, config: config, qemu: qemu)
            }
            guard let (path, _) = BridgeSockets.socket(for: interface) else {
                throw VitrineError.unsupported("bridging to \(interface) needs Vitrine's bridge helper (Settings › Networks › Install Bridge Helper) or socket_vmnet set up for \(interface)")
            }
            let link = NetworkLink(summary: "bridged to \(interface) via \(path)")
            link.watchGuest(bundle: bundle, config: config)
            do {
                if qemu {
                    try link.relayQEMU(bundle: bundle, toBridge: path)
                } else {
                    try link.relayVZ(toBridge: path)
                }
            } catch {
                link.close()
                throw error
            }
            return link
        }
    }

    /// A build signed with com.apple.vm.networking bridges in-process: VZ through its own bridged
    /// attachment, QEMU through a vmnet bridged interface relayed to its netdev socket.
    private static func openNativeBridge(interface: String, bundle: VMBundle, config: VMConfig, qemu: Bool) throws -> NetworkLink {
        let link = NetworkLink(summary: "bridged to \(interface) (com.apple.vm.networking)")
        if qemu {
            do {
                let port = try VmnetPort.startClassic(mode: .VMNET_BRIDGED_MODE, bridging: interface)
                link.port = port
                link.watchGuest(bundle: bundle, config: config)
                try link.serveQEMU(bundle: bundle, port: port)
            } catch {
                link.close()
                throw error
            }
            return link
        }
        guard let nic = VZBridgedNetworkInterface.networkInterfaces.first(where: { $0.identifier == interface }) else {
            throw VitrineError.invalidConfig("\(interface) can't be bridged (it isn't an Ethernet or Wi-Fi interface of this Mac)")
        }
        link.vzAttachment = VZBridgedNetworkDeviceAttachment(interface: nic)
        return link
    }

    /// Records the address the guest's frames show for the VM's process (`reportedGuestIP`).
    private func watchGuest(bundle: VMBundle, config: VMConfig) {
        guestAddress = GuestAddressWatcher(mac: config.network.macAddress,
                                           accept: { GuestNetwork.isPlausibleGuestAddress($0, for: config) },
                                           record: { bundle.recordGuestIP($0) })
    }

    /// QEMU's frames go to and from the vmnet interface.
    private func serveQEMU(bundle: VMBundle, port: VmnetPort) throws {
        port.onFrames { [weak self] in self?.toQEMU($0) }
        try listenForQEMU(bundle: bundle) { port.write($0) }
    }

    /// QEMU's frames go to and from the bridge socket.
    private func relayQEMU(bundle: VMBundle, toBridge path: String) throws {
        let bridgeFD = try UnixSocket.connect(path: path)
        UnixSocket.enlargeBuffers(bridgeFD)
        let bridge = FrameSocket(fd: bridgeFD, framing: .stream)
        self.bridge = bridge
        bridge.onFrames(queue: DispatchQueue(label: "vitrine.bridge-in"), { [weak self] in self?.toQEMU($0) }, onClose: { [summary] in
            NSLog("Vitrine: bridge connection closed (%@)", summary)
        })
        try listenForQEMU(bundle: bundle) { _ = bridge.write($0) }
    }

    private func toQEMU(_ frame: UnsafeRawBufferPointer) {
        lock.lock(); let conns = sockets; lock.unlock()
        for c in conns { c.write(frame) }
    }

    /// QEMU connects to net.sock in the bundle's socket directory; `send` takes the frames it sends.
    private func listenForQEMU(bundle: VMBundle, send: @escaping (UnsafeRawBufferPointer) -> Void) throws {
        let path = bundle.socketDirectory.appendingPathComponent("net.sock").path
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let fd = try UnixSocket.listen(path: path)
        listenPath = path
        qemuNetdev = "stream,server=off,addr.type=unix,addr.path=\(path)"
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            let conn = accept(fd, nil, nil)
            guard conn >= 0, let self else { if conn >= 0 { Darwin.close(conn) }; return }
            UnixSocket.enlargeBuffers(conn)
            let s = FrameSocket(fd: conn, framing: .stream)
            self.lock.lock()
            // QEMU reconnects after a restart of its netdev: the newest connection wins.
            let old = self.sockets
            self.sockets = [s]
            self.lock.unlock()
            old.forEach { $0.close() }
            s.onFrames(queue: self.queue, { [weak self] frame in
                self?.guestAddress?.observe(frame)
                send(frame)
            }, onClose: { [weak self, weak s] in
                guard let self, let s else { return }
                self.lock.lock(); self.sockets.removeAll { $0 === s }; self.lock.unlock()
            })
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        listener = source
    }

    /// The VM's datagram socket pair, relayed to the bridge's stream socket.
    private func relayVZ(toBridge path: String) throws {
        let bridgeFD = try UnixSocket.connect(path: path)
        UnixSocket.enlargeBuffers(bridgeFD)
        let (vmEnd, ourEnd) = try UnixSocket.datagramPair()
        let bridge = FrameSocket(fd: bridgeFD, framing: .stream)
        let vm = FrameSocket(fd: ourEnd, framing: .datagram)
        sockets = [bridge, vm]
        vzAttachment = VZFileHandleNetworkDeviceAttachment(fileHandle: FileHandle(fileDescriptor: vmEnd, closeOnDealloc: true))
        vm.onFrames(queue: queue, { [weak self] frame in
            self?.guestAddress?.observe(frame)
            bridge.write(frame)
        }, onClose: {})
        bridge.onFrames(queue: DispatchQueue(label: "vitrine.bridge-in"), { vm.write($0) }, onClose: { [summary] in
            NSLog("Vitrine: bridge connection closed (%@)", summary)
        })
    }

    func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let conns = sockets + [bridge].compactMap { $0 }
        sockets = []
        bridge = nil
        lock.unlock()
        listener?.cancel()
        listener = nil
        if let listenPath { unlink(listenPath) }
        conns.forEach { $0.close() }
        port?.stop()
        port = nil
        if let lease { VmnetNetworks.release(lease) }
        lease = nil
    }
}
