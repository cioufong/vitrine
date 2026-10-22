import Foundation

// Shared types for the emulated Bluetooth LE controller (docs/bluetooth.md). The controller speaks
// HCI to the guest's Bluetooth stack and drives a `BLERadio`, the Mac's Bluetooth (CoreBluetooth)
// in production and a fake in tests.

/// A Bluetooth UUID in ATT's little-endian wire form: 2 bytes for UUIDs built on the Bluetooth base
/// UUID that fit in 16 bits, 16 bytes otherwise. Always kept in the shortest form, so equal UUIDs
/// compare equal whichever form they arrived in.
public struct BTUUID: Hashable, Sendable, CustomStringConvertible {
    public let le: Data

    public init(_ short: UInt16) { le = Data([UInt8(short & 0xFF), UInt8(short >> 8)]) }

    /// From ATT wire bytes (2 or 16).
    public init?(le bytes: Data) {
        guard bytes.count == 2 || bytes.count == 16 else { return nil }
        le = BTUUID.shortest(Data(bytes))
    }

    /// From big-endian bytes as CoreBluetooth gives them (2, 4 or 16).
    public init?(bigEndian bytes: Data) {
        switch bytes.count {
        case 2, 16: le = BTUUID.shortest(Data(bytes.reversed()))
        case 4: le = BTUUID.shortest(Data((Data(bytes) + BTUUID.baseTail).reversed()))
        default: return nil
        }
    }

    private static func shortest(_ le: Data) -> Data {
        let b = [UInt8](le)
        guard b.count == 16, b[14] == 0, b[15] == 0, Array(b[0..<12]) == Array(baseTail.reversed()) else { return le }
        return Data(b[12...13])
    }

    /// The 12 bytes after the first four of the Bluetooth base UUID 0000xxxx-0000-1000-8000-00805F9B34FB.
    static let baseTail = Data([0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB])

    public var short: UInt16? { le.count == 2 ? UInt16(le[le.startIndex]) | UInt16(le[le.startIndex + 1]) << 8 : nil }

    /// The 128-bit little-endian form, for comparing a 16-bit UUID with a 128-bit one.
    public var full: Data {
        guard le.count == 2 else { return le }
        var be = Data([0, 0, le[le.startIndex + 1], le[le.startIndex]]) + BTUUID.baseTail
        be.reverse()
        return be
    }

    public var description: String {
        if let s = short { return String(format: "%04X", s) }
        return full.reversed().map { String(format: "%02X", $0) }.joined()
    }

    public static let primaryService = BTUUID(0x2800)
    public static let secondaryService = BTUUID(0x2801)
    public static let include = BTUUID(0x2802)
    public static let characteristic = BTUUID(0x2803)
    public static let clientConfiguration = BTUUID(0x2902)
    public static let gapService = BTUUID(0x1800)
    public static let gattService = BTUUID(0x1801)
    public static let deviceName = BTUUID(0x2A00)
    public static let appearance = BTUUID(0x2A01)
}

/// What one advertisement (with its scan response, which CoreBluetooth merges in) said.
public struct BLEAdvertisement: Equatable, Sendable {
    public var localName: String?
    public var serviceUUIDs: [BTUUID] = []
    public var manufacturerData: Data?
    public var serviceData: [BTUUID: Data] = [:]
    public var txPower: Int8?
    public var isConnectable = true
    public var rssi: Int8 = -127
    public init(localName: String? = nil, serviceUUIDs: [BTUUID] = [], manufacturerData: Data? = nil,
                serviceData: [BTUUID: Data] = [:], txPower: Int8? = nil, isConnectable: Bool = true, rssi: Int8 = -127) {
        self.localName = localName; self.serviceUUIDs = serviceUUIDs; self.manufacturerData = manufacturerData
        self.serviceData = serviceData; self.txPower = txPower; self.isConnectable = isConnectable; self.rssi = rssi
    }
}

/// A peripheral's GATT database as the radio discovered it. `id`s are the radio's own handles for
/// characteristics and descriptors; the controller assigns ATT handles itself.
public struct GATTService: Equatable, Sendable {
    public var uuid: BTUUID
    public var isPrimary: Bool
    public var characteristics: [GATTCharacteristic]
    public init(uuid: BTUUID, isPrimary: Bool = true, characteristics: [GATTCharacteristic]) {
        self.uuid = uuid; self.isPrimary = isPrimary; self.characteristics = characteristics
    }
}

public struct GATTCharacteristic: Equatable, Sendable {
    public var id: Int
    public var uuid: BTUUID
    /// ATT characteristic properties (0x02 read, 0x04 write without response, 0x08 write,
    /// 0x10 notify, 0x20 indicate, …).
    public var properties: UInt8
    public var descriptors: [GATTDescriptor]
    public init(id: Int, uuid: BTUUID, properties: UInt8, descriptors: [GATTDescriptor] = []) {
        self.id = id; self.uuid = uuid; self.properties = properties; self.descriptors = descriptors
    }
}

public struct GATTDescriptor: Equatable, Sendable {
    public var id: Int
    public var uuid: BTUUID
    public init(id: Int, uuid: BTUUID) { self.id = id; self.uuid = uuid }
}

/// An attribute the radio reads or writes: a characteristic's value or a descriptor.
public enum GATTTarget: Hashable, Sendable {
    case characteristic(Int)
    case descriptor(Int)
}

/// ATT error codes the controller answers with (radio errors carry one too).
public enum ATTError: UInt8, Error, Sendable {
    case invalidHandle = 0x01
    case readNotPermitted = 0x02
    case writeNotPermitted = 0x03
    case invalidPDU = 0x04
    case insufficientAuthentication = 0x05
    case requestNotSupported = 0x06
    case invalidOffset = 0x07
    case insufficientAuthorization = 0x08
    case prepareQueueFull = 0x09
    case attributeNotFound = 0x0A
    case attributeNotLong = 0x0B
    case insufficientEncryptionKeySize = 0x0C
    case invalidAttributeValueLength = 0x0D
    case unlikelyError = 0x0E
    case insufficientEncryption = 0x0F
    case unsupportedGroupType = 0x10
    case insufficientResources = 0x11
    /// A CCCD write asking for notifications or indications the characteristic doesn't do.
    case cccdImproperlyConfigured = 0xFD
}

/// What the controller needs from the Mac's Bluetooth. Every call and every callback into
/// `BLERadioDelegate` happens on the controller's queue.
public protocol BLERadio: AnyObject {
    var delegate: BLERadioDelegate? { get set }
    func startScan(allowDuplicates: Bool)
    func stopScan()
    func connect(_ peer: UUID)
    /// Gives up a connection attempt or ends a connection.
    func disconnect(_ peer: UUID)
    func read(_ peer: UUID, _ target: GATTTarget, completion: @escaping (Result<Data, ATTError>) -> Void)
    func write(_ peer: UUID, _ target: GATTTarget, value: Data, withResponse: Bool,
               completion: @escaping (Result<Void, ATTError>) -> Void)
    func setNotify(_ peer: UUID, characteristic: Int, enabled: Bool, completion: @escaping (Result<Void, ATTError>) -> Void)
    func stop()
}

public protocol BLERadioDelegate: AnyObject {
    func radio(discovered peer: UUID, _ advertisement: BLEAdvertisement)
    /// Connected and the peripheral's services fully discovered; `name` is its GAP name.
    func radio(connected peer: UUID, name: String?, services: [GATTService])
    func radio(failedToConnect peer: UUID)
    func radio(disconnected peer: UUID)
    func radio(notified peer: UUID, characteristic: Int, value: Data)
    /// The Mac's Bluetooth became unusable (off, permission withdrawn).
    func radio(unavailable reason: String)
}

// Little-endian helpers for the byte arrays HCI, L2CAP and ATT are parsed into.
extension Array where Element == UInt8 {
    func u16(_ i: Int) -> UInt16 { UInt16(self[i]) | UInt16(self[i + 1]) << 8 }
    mutating func put16(_ v: UInt16) { append(UInt8(truncatingIfNeeded: v)); append(UInt8(truncatingIfNeeded: v >> 8)) }
}
