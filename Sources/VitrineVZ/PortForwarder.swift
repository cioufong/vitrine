import Foundation
import Network
import VitrineCore

/// Port forwarding for guests with their own IP on a Mac-side network (Virtualization.framework,
/// and QEMU on vmnet or bridged networks): listens on the Mac and relays each TCP connection, or
/// each UDP peer's datagrams, to the guest's port. The guest's address is looked up per connection
/// (per UDP peer), so a guest that renews its lease is still reached.
final class PortForwarder: @unchecked Sendable {
    private var listeners: [NWListener] = []
    private var flows: [UUID: ForwardFlow] = [:]
    private var running = false
    private let queue = DispatchQueue(label: "vitrine.port-forward")
    private let guestAddress: @Sendable () -> String?
    private let log: @Sendable (String) -> Void

    init(guestAddress: @escaping @Sendable () -> String?, log: @escaping @Sendable (String) -> Void) {
        self.guestAddress = guestAddress
        self.log = log
    }

    /// UDP flows end after this long without a datagram either way.
    static let udpIdleTimeout: TimeInterval = 120

    func start(_ forwards: [VMConfig.PortForward]) {
        queue.sync {
            running = true
            startListeners(forwards)
        }
    }

    private func startListeners(_ forwards: [VMConfig.PortForward]) {
        for f in forwards {
            do {
                let params: NWParameters = f.proto == .tcp ? .tcp : .udp
                params.allowLocalEndpointReuse = true
                params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(f.hostAddress), port: NWEndpoint.Port(rawValue: UInt16(f.hostPort))!)
                let listener = try NWListener(using: params)
                listener.newConnectionHandler = { [weak self] client in
                    guard let self, self.running else { client.cancel(); return }
                    self.relay(client, to: f)
                }
                listener.stateUpdateHandler = { [log] state in
                    if case .failed(let error) = state { log("port forward \(f.spec) stopped: \(error.localizedDescription)") }
                }
                listener.start(queue: queue)
                listeners.append(listener)
                log("forwarding \(f.proto.rawValue) \(f.hostAddress):\(f.hostPort) → guest port \(f.guestPort)")
            } catch {
                log("port forward \(f.spec) failed: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        queue.sync {
            running = false
            for listener in listeners {
                listener.newConnectionHandler = nil
                listener.stateUpdateHandler = nil
                listener.cancel()
            }
            listeners = []
            for flow in Array(flows.values) { flow.close() }
        }
    }

    private func relay(_ client: NWConnection, to f: VMConfig.PortForward) {
        guard let ip = guestAddress(), let port = NWEndpoint.Port(rawValue: UInt16(f.guestPort)) else {
            log("port forward \(f.spec): the guest has no IP address yet")
            client.cancel()
            return
        }
        let guest = NWConnection(host: NWEndpoint.Host(ip), port: port, using: f.proto == .tcp ? .tcp : .udp)
        let id = UUID()
        let flow = ForwardFlow(client: client, guest: guest, queue: queue) { [weak self] in self?.flows[id] = nil }
        flows[id] = flow
        client.stateUpdateHandler = { [weak flow] state in
            if case .failed = state { flow?.close() }
            if case .cancelled = state { flow?.close() }
        }
        guest.stateUpdateHandler = { [weak flow] state in
            guard let flow else { return }
            switch state {
            case .ready:
                flow.start(udp: f.proto == .udp)
            case .failed, .waiting, .cancelled:
                flow.close()
            default: break
            }
        }
        client.start(queue: queue)
        guest.start(queue: queue)
    }
}

/// All state and callbacks belong to the forwarder's serial queue.
private final class ForwardFlow: @unchecked Sendable {
    let client: NWConnection, guest: NWConnection
    private let queue: DispatchQueue
    private let onClose: () -> Void
    private var lastActivity = Date()
    private var timer: DispatchSourceTimer?
    private var closed = false
    private var started = false
    private var endedDirections = 0

    init(client: NWConnection, guest: NWConnection, queue: DispatchQueue, onClose: @escaping () -> Void) {
        self.client = client; self.guest = guest; self.queue = queue; self.onClose = onClose
    }

    func start(udp: Bool) {
        guard !closed, !started else { return }
        started = true
        if udp {
            pumpUDP(from: client, to: guest)
            pumpUDP(from: guest, to: client)
            armTimer()
        } else {
            pumpTCP(from: client, to: guest)
            pumpTCP(from: guest, to: client)
        }
    }

    private func pumpTCP(from a: NWConnection, to b: NWConnection) {
        a.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            guard error == nil else { self.close(); return }
            let next = { [weak self] in
                guard let self, !self.closed else { return }
                if isComplete {
                    // Preserve half-close until the other direction drains too.
                    b.send(content: nil, isComplete: true, completion: .contentProcessed { [weak self] error in
                        guard let self, !self.closed else { return }
                        if error != nil { self.close(); return }
                        self.endedDirections += 1
                        if self.endedDirections == 2 { self.close() }
                    })
                } else {
                    self.pumpTCP(from: a, to: b)
                }
            }
            if let data, !data.isEmpty {
                b.send(content: data, completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.close() } else { next() }
                })
            } else {
                next()
            }
        }
    }

    private func pumpUDP(from a: NWConnection, to b: NWConnection) {
        a.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if error == nil, data != nil || isComplete {
                self.lastActivity = Date()
                b.send(content: data ?? Data(), completion: .idempotent)
            }
            if error != nil { self.close() } else { self.pumpUDP(from: a, to: b) }
        }
    }

    private func armTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 10, repeating: 10)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastActivity) > PortForwarder.udpIdleTimeout { self.close() }
        }
        t.resume()
        timer = t
    }

    func close() {
        guard !closed else { return }
        closed = true
        timer?.cancel()
        timer = nil
        client.stateUpdateHandler = nil
        guest.stateUpdateHandler = nil
        client.cancel()
        guest.cancel()
        onClose()
    }
}
