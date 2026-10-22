import Foundation

/// Rebuilds the AD structures of an advertisement CoreBluetooth has already parsed, so the guest's
/// stack sees much what the peripheral sent: what fits in the 31 bytes of advertising data goes
/// there, the rest in the scan response, and a name that fits neither is shortened.
enum AdvertisingData {
    static let maxLength = 31

    static func build(_ ad: BLEAdvertisement) -> (advertising: [UInt8], scanResponse: [UInt8]) {
        var structures: [[UInt8]] = []
        if ad.isConnectable { structures.append([0x01, 0x06]) }  // LE General Discoverable, no BR/EDR
        let short = ad.serviceUUIDs.filter { $0.le.count == 2 }
        let long = ad.serviceUUIDs.filter { $0.le.count == 16 }
        if !short.isEmpty { structures.append([0x03] + short.flatMap { [UInt8]($0.le) }) }
        if !long.isEmpty { structures.append([0x07] + long.flatMap { [UInt8]($0.le) }) }
        if let m = ad.manufacturerData, !m.isEmpty { structures.append([0xFF] + [UInt8](m)) }
        if let tx = ad.txPower { structures.append([0x0A, UInt8(bitPattern: tx)]) }
        for (uuid, data) in ad.serviceData.sorted(by: { $0.key.description < $1.key.description }) {
            structures.append([uuid.le.count == 2 ? 0x16 : 0x21] + [UInt8](uuid.le) + [UInt8](data))
        }

        var adv: [UInt8] = [], rsp: [UInt8] = []
        func place(_ s: [UInt8]) -> Bool {
            let entry = [UInt8(s.count)] + s
            if adv.count + entry.count <= maxLength { adv += entry; return true }
            if rsp.count + entry.count <= maxLength { rsp += entry; return true }
            return false
        }
        for s in structures { _ = place(s) }
        if let name = ad.localName, !name.isEmpty {
            let bytes = [UInt8](name.utf8)
            if !place([0x09] + bytes) {
                // Shortened Local Name in whichever payload has more room, cut on a character boundary.
                let room = max(maxLength - adv.count, maxLength - rsp.count) - 2
                if room > 0 {
                    var cut = String(decoding: bytes.prefix(room), as: UTF8.self)
                    while cut.utf8.count > room || cut.hasSuffix("\u{FFFD}") { cut.removeLast() }
                    if !cut.isEmpty { _ = place([0x08] + [UInt8](cut.utf8)) }
                }
            }
        }
        return (adv, rsp)
    }
}
