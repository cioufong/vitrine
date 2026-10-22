import CoreBluetooth
import Foundation

/// The Mac's Bluetooth as a `BLERadio`. CoreBluetooth calls back on `queue`, the controller's.
/// Connecting discovers the whole GATT database (services, characteristics, descriptors) before
/// reporting the peripheral connected.
public final class CoreBluetoothRadio: NSObject, BLERadio {
    public weak var delegate: BLERadioDelegate?
    private let queue: DispatchQueue
    private var central: CBCentralManager!
    private var scan: Bool?  // allowDuplicates, while scanning is wanted
    private var peripherals: [UUID: CBPeripheral] = [:]
    /// Peripherals connecting or discovering; the count is the discoveries still outstanding.
    private var discovering: [UUID: Int] = [:]
    private var connected: Set<UUID> = []
    private var characteristics: [Int: CBCharacteristic] = [:]
    private var descriptors: [Int: CBDescriptor] = [:]
    private var ids: [ObjectIdentifier: Int] = [:]
    private var nextID = 1
    private var reads: [ObjectIdentifier: [(Result<Data, ATTError>) -> Void]] = [:]
    private var writes: [ObjectIdentifier: [(Result<Void, ATTError>) -> Void]] = [:]
    private var notifyChanges: [ObjectIdentifier: [(Result<Void, ATTError>) -> Void]] = [:]
    private var unacknowledged: [UUID: [(CBCharacteristic, Data)]] = [:]
    static let maxUnacknowledgedWrites = 256

    public init(queue: DispatchQueue) {
        self.queue = queue
        super.init()
        central = CBCentralManager(delegate: self, queue: queue, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    public func startScan(allowDuplicates: Bool) {
        scan = allowDuplicates
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates])
    }

    public func stopScan() {
        scan = nil
        if central.state == .poweredOn { central.stopScan() }
    }

    public func connect(_ peer: UUID) {
        guard let p = peripherals[peer] ?? central.retrievePeripherals(withIdentifiers: [peer]).first,
              central.state == .poweredOn else {
            queue.async { self.delegate?.radio(failedToConnect: peer) }
            return
        }
        peripherals[peer] = p
        p.delegate = self
        discovering[peer] = 0
        central.connect(p)
    }

    public func disconnect(_ peer: UUID) {
        discovering[peer] = nil
        connected.remove(peer)
        forget(peer)
        if let p = peripherals[peer] { central.cancelPeripheralConnection(p) }
    }

    public func read(_ peer: UUID, _ target: GATTTarget, completion: @escaping (Result<Data, ATTError>) -> Void) {
        switch target {
        case .characteristic(let id):
            guard let c = characteristics[id], let p = c.service?.peripheral else { return completion(.failure(.invalidHandle)) }
            reads[ObjectIdentifier(c), default: []].append(completion)
            p.readValue(for: c)
        case .descriptor(let id):
            guard let d = descriptors[id], let p = d.characteristic?.service?.peripheral else { return completion(.failure(.invalidHandle)) }
            reads[ObjectIdentifier(d), default: []].append(completion)
            p.readValue(for: d)
        }
    }

    public func write(_ peer: UUID, _ target: GATTTarget, value: Data, withResponse: Bool,
                      completion: @escaping (Result<Void, ATTError>) -> Void) {
        switch target {
        case .characteristic(let id):
            guard let c = characteristics[id], let p = c.service?.peripheral else { return completion(.failure(.invalidHandle)) }
            if withResponse {
                writes[ObjectIdentifier(c), default: []].append(completion)
                p.writeValue(value, for: c, type: .withResponse)
            } else {
                // Write Commands are unacknowledged: while the peripheral is backed up, the guest
                // can't make this grow without bound, the newest are dropped.
                if unacknowledged[peer, default: []].count < Self.maxUnacknowledgedWrites {
                    unacknowledged[peer, default: []].append((c, value))
                }
                flushWrites(p)
                completion(.success(()))
            }
        case .descriptor(let id):
            guard let d = descriptors[id], let p = d.characteristic?.service?.peripheral else { return completion(.failure(.invalidHandle)) }
            writes[ObjectIdentifier(d), default: []].append(completion)
            p.writeValue(value, for: d)
        }
    }

    public func setNotify(_ peer: UUID, characteristic id: Int, enabled: Bool, completion: @escaping (Result<Void, ATTError>) -> Void) {
        guard let c = characteristics[id], let p = c.service?.peripheral else { return completion(.failure(.invalidHandle)) }
        guard c.properties.contains(.notify) || c.properties.contains(.indicate) else {
            return completion(enabled ? .failure(.requestNotSupported) : .success(()))
        }
        notifyChanges[ObjectIdentifier(c), default: []].append(completion)
        p.setNotifyValue(enabled, for: c)
    }

    public func stop() {
        stopScan()
        for peer in Array(peripherals.keys) where discovering[peer] != nil || connected.contains(peer) { disconnect(peer) }
        peripherals.removeAll()
    }

    /// Writes without response go out as fast as CoreBluetooth takes them, in order.
    private func flushWrites(_ p: CBPeripheral) {
        while var pending = unacknowledged[p.identifier], !pending.isEmpty, p.canSendWriteWithoutResponse {
            let (c, value) = pending.removeFirst()
            unacknowledged[p.identifier] = pending
            p.writeValue(value, for: c, type: .withoutResponse)
        }
    }

    private func forget(_ peer: UUID) {
        let gone = characteristics.filter { $0.value.service?.peripheral?.identifier == peer || $0.value.service == nil }
        for (id, c) in gone {
            characteristics[id] = nil
            ids[ObjectIdentifier(c)] = nil
            fail(ObjectIdentifier(c))
        }
        let goneDescriptors = descriptors.filter {
            $0.value.characteristic?.service?.peripheral?.identifier == peer || $0.value.characteristic == nil
        }
        for (id, d) in goneDescriptors {
            descriptors[id] = nil
            ids[ObjectIdentifier(d)] = nil
            fail(ObjectIdentifier(d))
        }
        unacknowledged[peer] = nil
    }

    private func fail(_ key: ObjectIdentifier) {
        reads.removeValue(forKey: key)?.forEach { $0(.failure(.unlikelyError)) }
        writes.removeValue(forKey: key)?.forEach { $0(.failure(.unlikelyError)) }
        notifyChanges.removeValue(forKey: key)?.forEach { $0(.failure(.unlikelyError)) }
    }

    static func attError(_ error: Error?) -> ATTError? {
        guard let error else { return nil }
        let e = error as NSError
        if e.domain == CBATTErrorDomain, let code = UInt8(exactly: e.code), let att = ATTError(rawValue: code) { return att }
        if e.domain == CBErrorDomain, e.code == CBError.peerRemovedPairingInformation.rawValue
            || e.code == CBError.encryptionTimedOut.rawValue {
            return .insufficientAuthentication
        }
        return .unlikelyError
    }

    private func id(for object: AnyObject) -> Int {
        if let id = ids[ObjectIdentifier(object)] { return id }
        let id = nextID
        nextID += 1
        ids[ObjectIdentifier(object)] = id
        return id
    }

    /// Discovery for `peer` finished: hand the controller its database.
    private func discovered(_ p: CBPeripheral) {
        discovering[p.identifier] = nil
        connected.insert(p.identifier)
        let services: [GATTService] = (p.services ?? []).compactMap { s in
            guard let uuid = BTUUID(bigEndian: s.uuid.data) else { return nil }
            let chars: [GATTCharacteristic] = (s.characteristics ?? []).compactMap { c in
                guard let cu = BTUUID(bigEndian: c.uuid.data) else { return nil }
                let cid = id(for: c)
                characteristics[cid] = c
                let descs: [GATTDescriptor] = (c.descriptors ?? []).compactMap { d in
                    guard let du = BTUUID(bigEndian: d.uuid.data) else { return nil }
                    let did = id(for: d)
                    descriptors[did] = d
                    return GATTDescriptor(id: did, uuid: du)
                }
                return GATTCharacteristic(id: cid, uuid: cu, properties: UInt8(c.properties.rawValue & 0xFF), descriptors: descs)
            }
            return GATTService(uuid: uuid, isPrimary: s.isPrimary, characteristics: chars)
        }
        delegate?.radio(connected: p.identifier, name: p.name, services: services)
    }

    /// One discovery step done (or `more` started) for a peripheral still being discovered.
    private func step(_ p: CBPeripheral, more: Int = 0) {
        guard let outstanding = discovering[p.identifier] else { return }
        let left = outstanding + more - 1
        discovering[p.identifier] = left
        if left == 0 { discovered(p) }
    }

    /// Descriptor values as CoreBluetooth gives them (Data, or NSNumber and String for the
    /// descriptors it decodes), back to bytes.
    static func bytes(_ value: Any?, uuid: CBUUID) -> Data {
        switch value {
        case let d as Data: return d
        case let s as String: return Data(s.utf8)
        case let n as NSNumber:
            let v = n.uint16Value
            return Data([UInt8(v & 0xFF), UInt8(v >> 8)])
        default: return Data()
        }
    }
}

extension CoreBluetoothRadio: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if let duplicates = scan { startScan(allowDuplicates: duplicates) }
        case .poweredOff:
            connected.removeAll()
            discovering.removeAll()
            delegate?.radio(unavailable: "Bluetooth is off on this Mac.")
        case .unauthorized:
            delegate?.radio(unavailable: "Vitrine isn't allowed to use Bluetooth. Allow it in System Settings > Privacy & Security > Bluetooth.")
        case .unsupported:
            delegate?.radio(unavailable: "This Mac doesn't support Bluetooth LE.")
        default: break
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        peripherals[peripheral.identifier] = peripheral
        var ad = BLEAdvertisement()
        ad.localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let uuids = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        ad.serviceUUIDs = uuids.compactMap { BTUUID(bigEndian: $0.data) }
        ad.manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        for (uuid, data) in advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:] {
            if let u = BTUUID(bigEndian: uuid.data) { ad.serviceData[u] = data }
        }
        ad.txPower = (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber).map { Int8(clamping: $0.intValue) }
        ad.isConnectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true
        ad.rssi = RSSI.intValue == 127 ? 127 : Int8(clamping: RSSI.intValue)
        delegate?.radio(discovered: peripheral.identifier, ad)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard discovering[peripheral.identifier] != nil else { return central.cancelPeripheralConnection(peripheral) }
        discovering[peripheral.identifier] = 1
        peripheral.discoverServices(nil)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard discovering.removeValue(forKey: peripheral.identifier) != nil else { return }
        delegate?.radio(failedToConnect: peripheral.identifier)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let peer = peripheral.identifier
        if discovering.removeValue(forKey: peer) != nil {
            forget(peer)
            delegate?.radio(failedToConnect: peer)
        } else if connected.remove(peer) != nil {
            forget(peer)
            delegate?.radio(disconnected: peer)
        }
    }
}

extension CoreBluetoothRadio: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        for s in services { peripheral.discoverCharacteristics(nil, for: s) }
        step(peripheral, more: services.count)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let chars = service.characteristics ?? []
        for c in chars { peripheral.discoverDescriptors(for: c) }
        step(peripheral, more: chars.count)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        step(peripheral)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let key = ObjectIdentifier(characteristic)
        var read: ((Result<Data, ATTError>) -> Void)?
        if var waiting = reads[key], !waiting.isEmpty {
            read = waiting.removeFirst()
            reads[key] = waiting
        }
        let result: Result<Data, ATTError> = Self.attError(error).map { .failure($0) } ?? .success(characteristic.value ?? Data())
        Self.deliver(result, read: read, notifying: characteristic.isNotifying) { value in
            guard let id = ids[key] else { return }
            delegate?.radio(notified: peripheral.identifier, characteristic: id, value: value)
        }
    }

    /// Where a characteristic value CoreBluetooth reports goes. Read results and notifications
    /// arrive through the same callback and can't be told apart, so a value answers the oldest
    /// pending read (it is the characteristic's current value either way) and, while subscribed,
    /// is also forwarded as a notification so none is lost. The guest may therefore get a read's
    /// result a second time as a notification, which is harmless.
    static func deliver(_ result: Result<Data, ATTError>, read: ((Result<Data, ATTError>) -> Void)?, notifying: Bool,
                        notify: (Data) -> Void) {
        read?(result)
        if case .success(let value) = result, read == nil || notifying { notify(value) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        let key = ObjectIdentifier(descriptor)
        guard var waiting = reads[key], !waiting.isEmpty else { return }
        let completion = waiting.removeFirst()
        reads[key] = waiting
        if let e = Self.attError(error) { completion(.failure(e)) } else { completion(.success(Self.bytes(descriptor.value, uuid: descriptor.uuid))) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Self.complete(Self.takeFirst(&writes, ObjectIdentifier(characteristic)), error)
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: Error?) {
        Self.complete(Self.takeFirst(&writes, ObjectIdentifier(descriptor)), error)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Self.complete(Self.takeFirst(&notifyChanges, ObjectIdentifier(characteristic)), error)
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        flushWrites(peripheral)
    }

    /// Removes the oldest waiting completion. Separate from calling it: a completion may start the
    /// next write at once, which needs the table while an `inout` borrow of it would still be live.
    private static func takeFirst(_ table: inout [ObjectIdentifier: [(Result<Void, ATTError>) -> Void]],
                                  _ key: ObjectIdentifier) -> ((Result<Void, ATTError>) -> Void)? {
        guard var waiting = table[key], !waiting.isEmpty else { return nil }
        let completion = waiting.removeFirst()
        table[key] = waiting
        return completion
    }

    private static func complete(_ completion: ((Result<Void, ATTError>) -> Void)?, _ error: Error?) {
        guard let completion else { return }
        if let e = attError(error) { completion(.failure(e)) } else { completion(.success(())) }
    }
}
