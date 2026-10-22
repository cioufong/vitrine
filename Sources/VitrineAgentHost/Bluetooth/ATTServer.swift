import Foundation

/// One connection's GATT server. It answers the guest's ATT requests from a database that mirrors
/// the peripheral's services as CoreBluetooth discovered them (CoreBluetooth hides the peripheral's
/// own handles, so this one numbers attributes itself) and forwards value reads and writes to the
/// radio. A GAP service carrying the peripheral's name is synthesized, as CoreBluetooth hides it too.
final class ATTServer {
    static let serverMTU = 247

    struct Attribute {
        enum Kind {
            case constant([UInt8])
            case value(GATTCharacteristic)
            case descriptor(GATTDescriptor)
            case clientConfiguration(GATTCharacteristic)
            case deviceName
        }
        let handle: UInt16
        let type: BTUUID
        let kind: Kind
        /// The last handle of a service declaration's group; the handle itself for anything else.
        var groupEnd: UInt16
    }

    private(set) var attributes: [Attribute] = []
    private(set) var mtu = 23
    private let peer: UUID
    private let radio: BLERadio
    private let send: ([UInt8]) -> Void
    private let name: String
    private var valueHandles: [Int: UInt16] = [:]
    private var clientConfiguration: [Int: UInt16] = [:]
    private var cache: [UInt16: [UInt8]] = [:]
    private var prepared: [(handle: UInt16, offset: Int, value: [UInt8])] = []
    private var queued: [[UInt8]] = []
    private var busy = false, pumping = false, closed = false
    /// Indications waiting for the guest to confirm the one outstanding (at most one at a time).
    private var indications: [[UInt8]] = []
    private var indicating = false
    static let maxPendingIndications = 32
    static let maxQueuedRequests = 32

    init(peer: UUID, name: String?, services: [GATTService], radio: BLERadio, send: @escaping ([UInt8]) -> Void) {
        self.peer = peer
        self.radio = radio
        self.send = send
        self.name = name ?? ""
        build(services)
    }

    private func build(_ services: [GATTService]) {
        func add(_ type: BTUUID, _ kind: Attribute.Kind) -> Int {
            let handle = UInt16(attributes.count + 1)
            attributes.append(Attribute(handle: handle, type: type, kind: kind, groupEnd: handle))
            return attributes.count - 1
        }
        func declare(_ properties: UInt8, _ uuid: BTUUID) {
            var decl: [UInt8] = [properties]
            decl.put16(UInt16(attributes.count + 2))
            decl += uuid.le
            _ = add(.characteristic, .constant(decl))
        }
        if !services.contains(where: { $0.uuid == .gapService }) {
            let gap = add(.primaryService, .constant([UInt8](BTUUID.gapService.le)))
            declare(0x02, .deviceName)
            _ = add(.deviceName, .deviceName)
            declare(0x02, .appearance)
            _ = add(.appearance, .constant([0, 0]))
            attributes[gap].groupEnd = UInt16(attributes.count)
        }
        for service in services {
            guard attributes.count < 0xFFF0 else { break }
            let start = add(service.isPrimary ? .primaryService : .secondaryService, .constant([UInt8](service.uuid.le)))
            for c in service.characteristics {
                declare(c.properties, c.uuid)
                valueHandles[c.id] = UInt16(attributes.count + 1)
                _ = add(c.uuid, .value(c))
                var hasCCCD = false
                for d in c.descriptors {
                    if d.uuid == .clientConfiguration {
                        hasCCCD = true
                        _ = add(.clientConfiguration, .clientConfiguration(c))
                    } else {
                        _ = add(d.uuid, .descriptor(d))
                    }
                }
                if c.properties & 0x30 != 0, !hasCCCD {
                    _ = add(.clientConfiguration, .clientConfiguration(c))
                }
            }
            attributes[start].groupEnd = UInt16(attributes.count)
        }
    }

    /// An ATT PDU from the guest.
    func receive(_ pdu: [UInt8]) {
        guard let op = pdu.first, !closed else { return }
        if op & 0x40 != 0 { command(pdu); return }
        if op == 0x1E {  // Handle Value Confirmation: the next indication may go
            indicating = false
            sendIndication()
            return
        }
        if op & 1 == 1 { return }  // responses to requests this server never makes
        // A client waits for each response before its next request; one that doesn't gets errors
        // rather than an ever-growing queue.
        guard queued.count < Self.maxQueuedRequests else {
            return send(Self.error(op, pdu.count >= 3 ? pdu.u16(1) : 0, .unlikelyError))
        }
        queued.append(pdu)
        pump()
    }

    /// A value the peripheral notified or indicated (CoreBluetooth has confirmed indications to it
    /// already). It reaches the guest the way the guest subscribed: as a notification, or as an
    /// indication when only indications are on. Unsubscribed, it's dropped.
    func notify(characteristic id: Int, value: Data) {
        guard !closed, let handle = valueHandles[id] else { return }
        let config = clientConfiguration[id] ?? 0
        guard config & 0x03 != 0 else { return }
        var pdu: [UInt8] = [config & 0x01 != 0 ? 0x1B : 0x1D]
        pdu.put16(handle)
        pdu += value.prefix(mtu - 3)
        guard pdu[0] == 0x1D else { return send(pdu) }
        // A guest that stops confirming can't make this grow without bound: the oldest go.
        if indications.count == Self.maxPendingIndications { indications.removeFirst() }
        indications.append(pdu)
        sendIndication()
    }

    private func sendIndication() {
        guard !indicating, !closed, !indications.isEmpty else { return }
        indicating = true
        send(indications.removeFirst())
    }

    func close() {
        closed = true
        queued.removeAll()
        cache.removeAll()
        indications.removeAll()
    }

    // MARK: Requests, one at a time as ATT requires

    private func pump() {
        guard !pumping else { return }
        pumping = true
        defer { pumping = false }
        while !busy, !closed, !queued.isEmpty {
            busy = true
            request(queued.removeFirst()) { [weak self] reply in
                guard let self, !self.closed else { return }
                self.send(reply)
                self.busy = false
                self.pump()
            }
        }
    }

    private static func error(_ op: UInt8, _ handle: UInt16, _ code: ATTError) -> [UInt8] {
        var pdu: [UInt8] = [0x01, op]
        pdu.put16(handle)
        pdu.append(code.rawValue)
        return pdu
    }

    private func attribute(_ handle: UInt16) -> Attribute? {
        handle >= 1 && Int(handle) <= attributes.count ? attributes[Int(handle) - 1] : nil
    }

    /// Attributes in `start...end`, or the error a bad range gets.
    private func range(_ op: UInt8, _ start: UInt16, _ end: UInt16) -> Result<ArraySlice<Attribute>, ATTError> {
        guard start != 0, start <= end else { return .failure(.invalidHandle) }
        let lo = Int(start) - 1, hi = min(Int(end), attributes.count)
        guard lo < hi else { return .failure(.attributeNotFound) }
        return .success(attributes[lo..<hi])
    }

    private func request(_ pdu: [UInt8], reply: @escaping ([UInt8]) -> Void) {
        let op = pdu[0]
        func fail(_ handle: UInt16, _ code: ATTError) { reply(Self.error(op, handle, code)) }
        switch op {
        case 0x02:  // Exchange MTU
            guard pdu.count == 3 else { return fail(0, .invalidPDU) }
            mtu = max(23, min(Int(pdu.u16(1)), Self.serverMTU))
            var rsp: [UInt8] = [0x03]
            rsp.put16(UInt16(Self.serverMTU))
            reply(rsp)

        case 0x04:  // Find Information
            guard pdu.count == 5 else { return fail(0, .invalidPDU) }
            let start = pdu.u16(1)
            switch range(op, start, pdu.u16(3)) {
            case .failure(let e): fail(start, e)
            case .success(let attrs):
                let size = attrs.first!.type.le.count
                var rsp: [UInt8] = [0x05, size == 2 ? 0x01 : 0x02]
                for a in attrs {
                    guard a.type.le.count == size, rsp.count + 2 + size <= mtu else { break }
                    rsp.put16(a.handle)
                    rsp += a.type.le
                }
                reply(rsp)
            }

        case 0x06:  // Find By Type Value
            guard pdu.count >= 7 else { return fail(0, .invalidPDU) }
            let start = pdu.u16(1), type = BTUUID(pdu.u16(5)), value = Array(pdu[7...])
            let wanted = BTUUID(le: Data(value))
            switch range(op, start, pdu.u16(3)) {
            case .failure(let e): fail(start, e)
            case .success(let attrs):
                var rsp: [UInt8] = [0x07]
                for a in attrs where a.type == type {
                    guard case .constant(let v) = a.kind else { continue }
                    let match = v == value || (wanted != nil && (type == .primaryService || type == .secondaryService)
                                               && BTUUID(le: Data(v)) == wanted)
                    guard match else { continue }
                    guard rsp.count + 4 <= mtu else { break }
                    rsp.put16(a.handle)
                    rsp.put16(a.groupEnd)
                }
                rsp.count > 1 ? reply(rsp) : fail(start, .attributeNotFound)
            }

        case 0x08:  // Read By Type
            guard pdu.count == 7 || pdu.count == 21, let type = BTUUID(le: Data(pdu[5...])) else { return fail(0, .invalidPDU) }
            let start = pdu.u16(1)
            switch range(op, start, pdu.u16(3)) {
            case .failure(let e): fail(start, e)
            case .success(let attrs):
                let matching = attrs.filter { $0.type == type }
                guard let first = matching.first else { return fail(start, .attributeNotFound) }
                let limit = min(mtu - 4, 253)
                func entries(_ pairs: [(UInt16, [UInt8])]) -> [UInt8] {
                    let len = pairs[0].1.count
                    var rsp: [UInt8] = [0x09, UInt8(2 + len)]
                    for (h, v) in pairs {
                        guard v.count == len, rsp.count + 2 + len <= mtu else { break }
                        rsp.put16(h)
                        rsp += v
                    }
                    return rsp
                }
                if local(first) != nil {
                    var pairs: [(UInt16, [UInt8])] = []
                    for a in matching {
                        guard let v = local(a) else { break }
                        pairs.append((a.handle, Array(v.prefix(limit))))
                    }
                    reply(entries(pairs))
                } else {
                    remoteRead(first, offset: 0, fresh: true) { result in
                        switch result {
                        case .success(let v): reply(entries([(first.handle, Array(v.prefix(limit)))]))
                        case .failure(let e): fail(first.handle, e)
                        }
                    }
                }
            }

        case 0x0A, 0x0C:  // Read, Read Blob
            guard pdu.count == (op == 0x0A ? 3 : 5) else { return fail(0, .invalidPDU) }
            let handle = pdu.u16(1), offset = op == 0x0C ? Int(pdu.u16(3)) : 0
            guard let a = attribute(handle) else { return fail(handle, .invalidHandle) }
            let finish = { (value: [UInt8]) in
                guard offset <= value.count else { return fail(handle, .invalidOffset) }
                reply([op + 1] + value[offset...].prefix(self.mtu - 1))
            }
            if let v = local(a) { return finish(v) }
            remoteRead(a, offset: offset, fresh: op == 0x0A) { result in
                switch result {
                case .success(let v): finish(v)
                case .failure(let e): fail(handle, e)
                }
            }

        case 0x10:  // Read By Group Type
            guard pdu.count == 7 || pdu.count == 21, let type = BTUUID(le: Data(pdu[5...])) else { return fail(0, .invalidPDU) }
            let start = pdu.u16(1)
            guard type == .primaryService || type == .secondaryService else { return fail(start, .unsupportedGroupType) }
            switch range(op, start, pdu.u16(3)) {
            case .failure(let e): fail(start, e)
            case .success(let attrs):
                var rsp: [UInt8] = [0x11, 0]
                var len = 0
                for a in attrs where a.type == type {
                    guard case .constant(let v) = a.kind else { continue }
                    if len == 0 { len = v.count; rsp[1] = UInt8(4 + len) }
                    guard v.count == len, rsp.count + 4 + len <= mtu else { break }
                    rsp.put16(a.handle)
                    rsp.put16(a.groupEnd)
                    rsp += v
                }
                len > 0 ? reply(rsp) : fail(start, .attributeNotFound)
            }

        case 0x12:  // Write
            guard pdu.count >= 3 else { return fail(0, .invalidPDU) }
            let handle = pdu.u16(1)
            write(handle, Array(pdu[3...]), withResponse: true) { error in
                if let error { fail(handle, error) } else { reply([0x13]) }
            }

        case 0x16:  // Prepare Write
            guard pdu.count >= 5 else { return fail(0, .invalidPDU) }
            let handle = pdu.u16(1)
            guard let a = attribute(handle) else { return fail(handle, .invalidHandle) }
            guard writable(a) else { return fail(handle, .writeNotPermitted) }
            guard prepared.count < 128 else { return fail(handle, .prepareQueueFull) }
            prepared.append((handle, Int(pdu.u16(3)), Array(pdu[5...])))
            reply([0x17] + pdu[1...])

        case 0x18:  // Execute Write
            guard pdu.count == 2 else { return fail(0, .invalidPDU) }
            let queue = prepared
            prepared.removeAll()
            guard pdu[1] == 1 else { return reply([0x19]) }
            var values: [(UInt16, [UInt8])] = []
            for entry in queue {
                let i = values.firstIndex { $0.0 == entry.handle } ?? { values.append((entry.handle, [])); return values.count - 1 }()
                var v = values[i].1
                guard entry.offset <= v.count else { return fail(entry.handle, .invalidOffset) }
                v.replaceSubrange(entry.offset..<min(entry.offset + entry.value.count, v.count), with: entry.value)
                values[i].1 = v
            }
            func next(_ i: Int) {
                guard i < values.count else { return reply([0x19]) }
                write(values[i].0, values[i].1, withResponse: true) { error in
                    if let error { fail(values[i].0, error) } else { next(i + 1) }
                }
            }
            next(0)

        default:
            fail(0, .requestNotSupported)
        }
    }

    private func command(_ pdu: [UInt8]) {
        // Write Command; a Signed Write (0xD2) needs a signing key this link never has.
        guard pdu[0] == 0x52, pdu.count >= 3 else { return }
        write(pdu.u16(1), Array(pdu[3...]), withResponse: false) { _ in }
    }

    // MARK: Attribute values

    /// The value of an attribute this server holds itself.
    private func local(_ a: Attribute) -> [UInt8]? {
        switch a.kind {
        case .constant(let v): return v
        case .deviceName: return [UInt8](name.utf8)
        case .clientConfiguration(let c):
            var v: [UInt8] = []
            v.put16(clientConfiguration[c.id] ?? 0)
            return v
        case .value, .descriptor: return nil
        }
    }

    /// Reads a value from the peripheral. CoreBluetooth reads long values whole, so blob reads past
    /// the start are served from the last read.
    private func remoteRead(_ a: Attribute, offset: Int, fresh: Bool, completion: @escaping (Result<[UInt8], ATTError>) -> Void) {
        if !fresh, offset > 0, let cached = cache[a.handle] { return completion(.success(cached)) }
        let target: GATTTarget
        switch a.kind {
        case .value(let c):
            guard c.properties & 0x02 != 0 else { return completion(.failure(.readNotPermitted)) }
            target = .characteristic(c.id)
        case .descriptor(let d): target = .descriptor(d.id)
        default: return completion(.failure(.readNotPermitted))
        }
        radio.read(peer, target) { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .success(let data):
                let v = [UInt8](data)
                self.cache[a.handle] = v
                completion(.success(v))
            case .failure(let e): completion(.failure(e))
            }
        }
    }

    private func writable(_ a: Attribute) -> Bool {
        switch a.kind {
        case .value(let c): return c.properties & 0x0C != 0
        case .descriptor, .clientConfiguration: return true
        case .constant, .deviceName: return false
        }
    }

    private func write(_ handle: UInt16, _ value: [UInt8], withResponse: Bool, completion: @escaping (ATTError?) -> Void) {
        guard let a = attribute(handle) else { return completion(.invalidHandle) }
        cache[handle] = nil
        let done: (Result<Void, ATTError>) -> Void = { [weak self] result in
            guard let self, !self.closed else { return }
            if case .failure(let e) = result { completion(e) } else { completion(nil) }
        }
        switch a.kind {
        case .value(let c):
            let allowed = withResponse ? c.properties & 0x08 != 0 : c.properties & 0x04 != 0
            guard allowed else { return completion(.writeNotPermitted) }
            radio.write(peer, .characteristic(c.id), value: Data(value), withResponse: withResponse, completion: done)
        case .descriptor(let d):
            guard withResponse else { return completion(.writeNotPermitted) }
            radio.write(peer, .descriptor(d.id), value: Data(value), withResponse: true, completion: done)
        case .clientConfiguration(let c):
            // Write Commands skip the one-at-a-time request queue; subscriptions go one at a time.
            guard withResponse else { return completion(.writeNotPermitted) }
            guard value.count == 2 else { return completion(.invalidAttributeValueLength) }
            let config = value.u16(0)
            guard config & 0x01 == 0 || c.properties & 0x10 != 0, config & 0x02 == 0 || c.properties & 0x20 != 0 else {
                return completion(.cccdImproperlyConfigured)
            }
            let id = c.id
            radio.setNotify(peer, characteristic: id, enabled: config & 0x03 != 0) { [weak self] result in
                if case .success = result { self?.clientConfiguration[id] = config }
                done(result)
            }
        case .constant, .deviceName:
            completion(.writeNotPermitted)
        }
    }
}
