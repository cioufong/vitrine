import Foundation

/// An emulated Bluetooth 4.2 LE-only controller. The guest's kernel drives it over HCI (H4 packets,
/// type byte first) as it would a UART controller; scans and connections go out through a
/// `BLERadio`, the Mac's Bluetooth. Peripherals appear under random static addresses derived from
/// CoreBluetooth's identifiers, since CoreBluetooth never reveals the real ones. Not thread-safe:
/// call it, and have the radio call back, on one queue.
public final class BLEController: BLERadioDelegate {
    static let aclMTU = 251, aclBuffers = 8

    private let address: [UInt8]
    private let radio: BLERadio
    private let send: (Data) -> Void
    /// The Mac's Bluetooth became unusable.
    public var onUnavailable: ((String) -> Void)?

    private final class Connection {
        let handle: UInt16, peer: UUID, address: [UInt8]
        var att: ATTServer!
        var rx: [UInt8] = []
        init(handle: UInt16, peer: UUID, address: [UInt8]) { self.handle = handle; self.peer = peer; self.address = address }
    }

    private struct PendingConnection {
        var address: [UInt8]
        /// The addresses the connection may go to: the peer's, or the whole accept list.
        var candidates: Set<[UInt8]>
        var peer: UUID?
        var interval: UInt16, latency: UInt16, timeout: UInt16
    }

    private var localName: [UInt8] = []
    private var hostScanning = false, activeScan = false, filterDuplicates = false
    private var radioScanning: Bool?
    private var acceptList: Set<[UInt8]> = []
    private var peers: [[UInt8]: UUID] = [:]
    private var names: [UUID: String] = [:]
    private var pending: PendingConnection?
    private var connections: [UInt16: Connection] = [:]
    private var nextHandle: UInt16 = 0x0040

    /// `address` is the controller's own (public) address, six bytes little-endian.
    public init(address: [UInt8], radio: BLERadio, send: @escaping (Data) -> Void) {
        precondition(address.count == 6)
        self.address = address
        self.radio = radio
        self.send = send
        radio.delegate = self
    }

    /// A random static address for a CoreBluetooth peripheral identifier, little-endian.
    static func address(for peer: UUID) -> [UInt8] {
        let u = peer.uuid
        return [u.0, u.1, u.2, u.3, u.4, u.5 | 0xC0]
    }

    /// One H4 packet from the guest.
    public func receive(_ packet: Data) {
        let p = [UInt8](packet)
        guard let type = p.first else { return }
        switch type {
        case 0x01: command(Array(p.dropFirst()))
        case 0x02: acl(Array(p.dropFirst()))
        default: break  // SCO and ISO: never set up
        }
    }

    /// Drops every connection and stops the radio, telling the guest nothing.
    public func shutdown() {
        reset()
        radio.stop()
    }

    // MARK: Events

    private func event(_ code: UInt8, _ params: [UInt8]) {
        send(Data([0x04, code, UInt8(params.count)] + params))
    }

    private func complete(_ opcode: UInt16, _ ret: [UInt8]) {
        var p: [UInt8] = [1]
        p.put16(opcode)
        event(0x0E, p + ret)
    }

    private func status(_ opcode: UInt16, _ status: UInt8) {
        var p: [UInt8] = [status, 1]
        p.put16(opcode)
        event(0x0F, p)
    }

    private func le(_ subevent: UInt8, _ params: [UInt8]) { event(0x3E, [subevent] + params) }

    // MARK: Commands

    /// What Read Local Supported Commands reports: exactly the commands handled below.
    static let supportedCommands: [UInt8] = {
        var c = [UInt8](repeating: 0, count: 64)
        c[0] |= 0x20          // Disconnect
        c[2] |= 0x80          // Read Remote Version Information
        c[5] |= 0xC0          // Set Event Mask, Reset
        c[14] |= 0xA8         // Read Local Version Information, Read Local Supported Features, Read Buffer Size
        c[15] |= 0x02         // Read BD_ADDR
        c[25] |= 0xF7         // LE Set Event Mask, Read Buffer Size, Read Local Features, Set Random Address,
                              // Set Advertising Parameters, Read Advertising Tx Power, Set Advertising Data
        c[26] |= 0xFF         // LE Set Scan Response Data … LE Clear Filter Accept List
        c[27] |= 0x27         // LE Add/Remove Filter Accept List, Connection Update, Read Remote Features
        c[28] |= 0x08         // LE Read Supported States
        return c
    }()

    /// LMP features: BR/EDR not supported, LE supported (controller).
    static let lmpFeatures: [UInt8] = [0, 0, 0, 0, 0x60, 0, 0, 0]

    private func command(_ b: [UInt8]) {
        guard b.count >= 3 else { return }
        let opcode = b.u16(0)
        let params = Array(b.dropFirst(3))
        guard params.count >= Int(b[2]) else { return complete(opcode, [0x12]) }
        func need(_ n: Int) -> Bool {
            if params.count >= n { return true }
            complete(opcode, [0x12])  // Invalid HCI Command Parameters
            return false
        }
        switch opcode {
        case 0x0C03:  // Reset
            reset()
            complete(opcode, [0])
        case 0x0C01, 0x2001, 0x0C6D, 0x2005, 0x2006, 0x2008, 0x2009, 0x200A:
            // Event masks, LE Host Supported, and advertising, which this controller doesn't do.
            complete(opcode, [0])
        case 0x0C13:  // Write Local Name: always 248 bytes, NUL-padded
            guard b[2] == 248 else { return complete(opcode, [0x12]) }
            localName = Array(params.prefix(248).prefix { $0 != 0 })
            complete(opcode, [0])
        case 0x0C14:  // Read Local Name
            let name = localName.prefix(248)
            complete(opcode, [0] + name + [UInt8](repeating: 0, count: 248 - name.count))
        case 0x0C6C:  // Read LE Host Supported
            complete(opcode, [0, 1, 0])
        case 0x1001:  // Read Local Version Information: 4.2, manufacturer 0xFFFF (none)
            complete(opcode, [0, 0x08, 0, 0, 0x08, 0xFF, 0xFF, 0, 0])
        case 0x1002:
            complete(opcode, [0] + Self.supportedCommands)
        case 0x1003:
            complete(opcode, [0] + Self.lmpFeatures)
        case 0x1005:  // Read Buffer Size
            var r: [UInt8] = [0]
            r.put16(UInt16(Self.aclMTU)); r.append(0); r.put16(UInt16(Self.aclBuffers)); r.put16(0)
            complete(opcode, r)
        case 0x1009:
            complete(opcode, [0] + address)
        case 0x2002:  // LE Read Buffer Size
            var r: [UInt8] = [0]
            r.put16(UInt16(Self.aclMTU)); r.append(UInt8(Self.aclBuffers))
            complete(opcode, r)
        case 0x2003:  // LE Read Local Supported Features: none beyond the basics
            complete(opcode, [0] + [UInt8](repeating: 0, count: 8))
        case 0x2007:  // LE Read Advertising Physical Channel Tx Power
            complete(opcode, [0, 0])
        case 0x200B:  // LE Set Scan Parameters
            guard need(7) else { return }
            guard !hostScanning else { return complete(opcode, [0x0C]) }
            activeScan = params[0] == 1
            complete(opcode, [0])
        case 0x200C:  // LE Set Scan Enable
            guard need(2) else { return }
            hostScanning = params[0] == 1
            filterDuplicates = params[1] == 1
            updateRadioScan(restart: hostScanning)
            complete(opcode, [0])
        case 0x200D:
            guard need(25) else { return }
            createConnection(params)
        case 0x200E:  // LE Create Connection Cancel
            guard let p = pending else { return complete(opcode, [0x0C]) }
            pending = nil
            if let peer = p.peer { radio.disconnect(peer) }
            updateRadioScan()
            complete(opcode, [0])
            connectionComplete(status: 0x02, handle: 0, address: p.address, p)
        case 0x200F:  // LE Read Filter Accept List Size
            complete(opcode, [0, 16])
        case 0x2010:
            acceptList.removeAll()
            complete(opcode, [0])
        case 0x2011, 0x2012:  // LE Add/Remove Device To/From Filter Accept List
            guard need(7) else { return }
            let a = Array(params[1...6])
            if opcode == 0x2011 { acceptList.insert(a) } else { acceptList.remove(a) }
            complete(opcode, [0])
        case 0x2013:  // LE Connection Update
            guard need(14) else { return }
            let handle = params.u16(0)
            guard connections[handle] != nil else { return status(opcode, 0x02) }
            status(opcode, 0)
            var e: [UInt8] = [0]
            e.put16(handle); e.put16(params.u16(4)); e.put16(params.u16(6)); e.put16(params.u16(8))
            le(0x03, e)
        case 0x2016:  // LE Read Remote Features
            guard need(2) else { return }
            let handle = params.u16(0)
            guard connections[handle] != nil else { return status(opcode, 0x02) }
            status(opcode, 0)
            var e: [UInt8] = [0]
            e.put16(handle)
            le(0x04, e + [UInt8](repeating: 0, count: 8))
        case 0x201C:  // LE Read Supported States: all the legacy combinations
            complete(opcode, [0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x03, 0, 0])
        case 0x0406:  // Disconnect
            guard need(3) else { return }
            let handle = params.u16(0)
            guard let c = connections.removeValue(forKey: handle) else { return status(opcode, 0x02) }
            status(opcode, 0)
            c.att.close()
            radio.disconnect(c.peer)
            disconnectionComplete(handle, reason: 0x16)
        case 0x041D:  // Read Remote Version Information
            guard need(2) else { return }
            let handle = params.u16(0)
            guard connections[handle] != nil else { return status(opcode, 0x02) }
            status(opcode, 0)
            var e: [UInt8] = [0]
            e.put16(handle)
            event(0x0C, e + [0x08, 0xFF, 0xFF, 0, 0])
        default:
            complete(opcode, [0x01])  // Unknown HCI Command
        }
    }

    private func reset() {
        for c in connections.values {
            c.att.close()
            radio.disconnect(c.peer)
        }
        connections.removeAll()
        if let peer = pending?.peer { radio.disconnect(peer) }
        pending = nil
        hostScanning = false
        activeScan = false
        acceptList.removeAll()
        localName = []
        updateRadioScan()
    }

    /// The radio scans while the guest scans, and while a connection waits for a peripheral this
    /// controller hasn't seen yet.
    private func updateRadioScan(restart: Bool = false) {
        let want = hostScanning || (pending != nil && pending?.peer == nil)
        let duplicates = hostScanning && !filterDuplicates
        if want, radioScanning != duplicates || restart {
            radio.startScan(allowDuplicates: duplicates)
            radioScanning = duplicates
        } else if !want, radioScanning != nil {
            radio.stopScan()
            radioScanning = nil
        }
    }

    private func createConnection(_ p: [UInt8]) {
        let opcode: UInt16 = 0x200D
        guard pending == nil else { return status(opcode, 0x0C) }  // Command Disallowed
        // Initiator filter policy 1 connects to whichever accept-listed device turns up: one seen
        // already, or else the first to advertise.
        let candidates: Set<[UInt8]> = p[4] == 1 ? acceptList : [Array(p[6...11])]
        guard let address = candidates.first(where: { peers[$0] != nil }) ?? candidates.first else {
            return status(opcode, 0x12)
        }
        status(opcode, 0)
        pending = PendingConnection(address: address, candidates: candidates, peer: peers[address],
                                    interval: p.u16(13), latency: p.u16(17), timeout: p.u16(19))
        if let peer = pending?.peer { radio.connect(peer) }
        updateRadioScan()
    }

    private func connectionComplete(status: UInt8, handle: UInt16, address: [UInt8], _ p: PendingConnection) {
        var e: [UInt8] = [status]
        e.put16(handle)
        e += [0x00, 0x01]  // central; peer random
        e += address
        e.put16(p.interval); e.put16(p.latency); e.put16(p.timeout)
        e.append(0x00)
        le(0x01, e)
    }

    private func disconnectionComplete(_ handle: UInt16, reason: UInt8) {
        var e: [UInt8] = [0]
        e.put16(handle)
        e.append(reason)
        event(0x05, e)
    }

    // MARK: ACL data and L2CAP

    private func acl(_ b: [UInt8]) {
        guard b.count >= 4 else { return }
        let header = b.u16(0), handle = header & 0x0FFF, boundary = (header >> 12) & 0x3
        let length = Int(b.u16(2))
        guard b.count >= 4 + length, let c = connections[handle] else { return }
        let data = b[4..<(4 + length)]
        if boundary == 0x1 { c.rx += data } else { c.rx = Array(data) }
        var e: [UInt8] = [1]  // Number Of Completed Packets: the controller's buffer is free again
        e.put16(handle); e.put16(1)
        event(0x13, e)
        while c.rx.count >= 4 {
            let len = Int(c.rx.u16(0))
            guard c.rx.count >= 4 + len else { break }
            let cid = c.rx.u16(2)
            let payload = Array(c.rx[4..<(4 + len)])
            c.rx.removeFirst(4 + len)
            l2cap(c, cid, payload)
        }
    }

    private func l2cap(_ c: Connection, _ cid: UInt16, _ payload: [UInt8]) {
        switch cid {
        case 0x0004: c.att.receive(payload)
        case 0x0005: signaling(c, payload)
        case 0x0006:
            // SMP: CoreBluetooth pairs with the peripheral itself when it must, so the guest
            // can't; tell it pairing isn't supported.
            if payload.first == 0x01 { sendL2CAP(c.handle, 0x0006, [0x05, 0x05]) }
        default: break
        }
    }

    private func signaling(_ c: Connection, _ payload: [UInt8]) {
        guard payload.count >= 4 else { return }
        let code = payload[0], id = payload[1]
        switch code {
        case 0x14:  // LE Credit Based Connection Request: no PSMs here
            sendL2CAP(c.handle, 0x0005, [0x15, id, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x02, 0x00])
        case 0x16, 0x18, 0x1A: break  // credits and enhanced-credit responses
        case let code where code & 1 == 1: break  // responses
        default:
            sendL2CAP(c.handle, 0x0005, [0x01, id, 2, 0, 0, 0])  // Command Reject: not understood
        }
    }

    private func sendL2CAP(_ handle: UInt16, _ cid: UInt16, _ payload: [UInt8]) {
        var frame: [UInt8] = []
        frame.put16(UInt16(payload.count))
        frame.put16(cid)
        frame += payload
        var offset = 0
        while offset < frame.count {
            let chunk = frame[offset..<min(offset + Self.aclMTU, frame.count)]
            var packet: [UInt8] = [0x02]
            packet.put16(handle | (offset == 0 ? 0x2000 : 0x1000))
            packet.put16(UInt16(chunk.count))
            send(Data(packet + chunk))
            offset += chunk.count
        }
    }

    // MARK: BLERadioDelegate

    public func radio(discovered peer: UUID, _ advertisement: BLEAdvertisement) {
        let address = Self.address(for: peer)
        peers[address] = peer
        if let name = advertisement.localName { names[peer] = name }
        if var p = pending, p.peer == nil, advertisement.isConnectable, p.candidates.contains(address) {
            p.address = address
            p.peer = peer
            pending = p
            radio.connect(peer)
            updateRadioScan()
        }
        guard hostScanning else { return }
        let (adv, rsp) = AdvertisingData.build(advertisement)
        let scanResponse = activeScan && !rsp.isEmpty
        let type: UInt8 = advertisement.isConnectable ? 0x00 : (scanResponse ? 0x02 : 0x03)
        report(type, address, adv, advertisement.rssi)
        if scanResponse { report(0x04, address, rsp, advertisement.rssi) }
    }

    private func report(_ type: UInt8, _ address: [UInt8], _ data: [UInt8], _ rssi: Int8) {
        le(0x02, [1, type, 0x01] + address + [UInt8(data.count)] + data + [UInt8(bitPattern: rssi)])
    }

    public func radio(connected peer: UUID, name: String?, services: [GATTService]) {
        guard let p = pending, p.peer == peer else { return radio.disconnect(peer) }
        pending = nil
        let handle = nextHandle
        nextHandle = nextHandle >= 0x0EFF ? 0x0040 : nextHandle + 1
        let c = Connection(handle: handle, peer: peer, address: p.address)
        c.att = ATTServer(peer: peer, name: name ?? names[peer], services: services, radio: radio) { [weak self] pdu in
            self?.sendL2CAP(handle, 0x0004, pdu)
        }
        connections[handle] = c
        connectionComplete(status: 0, handle: handle, address: p.address, p)
    }

    public func radio(failedToConnect peer: UUID) {
        guard let p = pending, p.peer == peer else { return }
        pending = nil
        connectionComplete(status: 0x3E, handle: 0, address: p.address, p)  // Failed to Be Established
    }

    public func radio(disconnected peer: UUID) {
        guard let c = connections.values.first(where: { $0.peer == peer }) else { return }
        connections[c.handle] = nil
        c.att.close()
        disconnectionComplete(c.handle, reason: 0x13)  // Remote User Terminated Connection
    }

    public func radio(notified peer: UUID, characteristic: Int, value: Data) {
        connections.values.first { $0.peer == peer }?.att.notify(characteristic: characteristic, value: value)
    }

    public func radio(unavailable reason: String) {
        for c in connections.values {
            c.att.close()
            disconnectionComplete(c.handle, reason: 0x08)  // Connection Timeout
        }
        connections.removeAll()
        if let p = pending {
            pending = nil
            connectionComplete(status: 0x3E, handle: 0, address: p.address, p)
        }
        onUnavailable?(reason)
    }
}
