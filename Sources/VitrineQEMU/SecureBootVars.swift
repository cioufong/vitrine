import Foundation
import VitrineCore

/// Enrolls Secure Boot keys into an EDK2 (OVMF) variable store file, as firmware setup would:
/// a platform key generated for this VM, Microsoft's KEKs and its Windows and third-party CAs in db,
/// and SecureBootEnable set, so the firmware boots with Secure Boot enforced. dbx (revocations) is
/// left empty. Layout per edk2's MdeModulePkg (VariableFormat.h) and MdePkg (ImageAuthentication.h).
public enum SecureBootVars {
    // EFI GUIDs as stored on disk (first three fields little-endian).
    static func guid(_ s: String) -> Data {
        let hex = s.replacingOccurrences(of: "-", with: "")
        let b = stride(from: 0, to: 32, by: 2).map { UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)..<hex.index(hex.startIndex, offsetBy: $0 + 2)], radix: 16)! }
        return Data([b[3], b[2], b[1], b[0], b[5], b[4], b[7], b[6]] + b[8...])
    }
    static let authenticatedVariableGuid = guid("aaf32c78-947b-439a-a180-2e144ec37792")
    static let globalVariableGuid = guid("8be4df61-93ca-11d2-aa0d-00e098032b8c")
    static let imageSecurityDatabaseGuid = guid("d719b2cb-3d3a-4596-a3bc-dad00e67656f")
    static let secureBootEnableGuid = guid("f0a30bc7-af08-4556-99c4-001009c93a44")
    static let customModeGuid = guid("c076ec0c-7028-4399-a072-71ee5c448b9f")
    static let certX509Guid = guid("a5c059a1-94e4-4aa7-87b5-ab155c2bf072")
    static let microsoftOwnerGuid = guid("77fa9abd-0359-4d32-bd60-28f4e78f784b")

    static let nonVolatile: UInt32 = 0x1, bootService: UInt32 = 0x2, runtime: UInt32 = 0x4
    static let timeBasedAuthenticatedWrite: UInt32 = 0x20
    static let variableHeaderSize = 60

    /// One EFI_SIGNATURE_LIST per X.509 certificate (their sizes differ).
    static func signatureLists(_ certs: [Data], owner: Data) -> Data {
        var out = Data()
        for der in certs {
            let sigSize = UInt32(16 + der.count)
            out += certX509Guid
            out += le(UInt32(28) + sigSize) + le(UInt32(0)) + le(sigSize)
            out += owner + der
        }
        return out
    }

    static func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    /// AUTHENTICATED_VARIABLE_HEADER + UTF-16 name + data, then 0xFF up to the next 4-byte boundary.
    static func variable(name: String, vendor: Data, attributes: UInt32, data: Data, time: Date) -> Data {
        var nameBytes = Data()
        for unit in name.utf16 { nameBytes += le(unit) }
        nameBytes += le(UInt16(0))
        var v = Data()
        v += le(UInt16(0x55AA))        // StartId
        v += Data([0x3F, 0])           // State = VAR_ADDED, Reserved
        v += le(attributes)
        v += le(UInt64(0))             // MonotonicCount
        v += efiTime(time)
        v += le(UInt32(0))             // PubKeyIndex
        v += le(UInt32(nameBytes.count)) + le(UInt32(data.count))
        v += vendor
        assert(v.count == variableHeaderSize)
        // Data follows the name directly (edk2's GET_PAD_SIZE is 0: ALIGNMENT is 1 on x86 and Arm);
        // only the next variable header is 4-byte aligned (HEADER_ALIGN).
        v += nameBytes
        v += data
        v += Data(repeating: 0xFF, count: (4 - v.count % 4) % 4)
        return v
    }

    static func efiTime(_ date: Date) -> Data {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        var t = Data()
        t += le(UInt16(c.year!)) + Data([UInt8(c.month!), UInt8(c.day!), UInt8(c.hour!), UInt8(c.minute!), UInt8(c.second!), 0])
        t += le(UInt32(0)) + le(Int16(0x07FF)) + Data([0, 0])   // Nanosecond, TimeZone unspecified, Daylight, Pad2
        return t
    }

    /// Writes the variables into the first free space of the authenticated variable store in
    /// `varsFile` (an EDK2 vars image such as edk2-i386-vars.fd). Refuses stores that already hold
    /// Secure Boot keys.
    public static func enroll(_ varsFile: URL, platformKey: Data, time: Date = Date()) throws {
        var image = try Data(contentsOf: varsFile)
        guard image.count > 0x100, image[40..<44] == Data("_FVH".utf8) else {
            throw VitrineError.invalidConfig("\(varsFile.lastPathComponent) is not a firmware volume")
        }
        let headerLength = Int(image[48]) | Int(image[49]) << 8
        guard image[headerLength..<headerLength + 16] == authenticatedVariableGuid else {
            throw VitrineError.unsupported("\(varsFile.lastPathComponent) has no authenticated variable store")
        }
        let storeSize = Int(UInt32(image[headerLength + 16]) | UInt32(image[headerLength + 17]) << 8
                            | UInt32(image[headerLength + 18]) << 16 | UInt32(image[headerLength + 19]) << 24)
        let storeEnd = headerLength + storeSize
        // Walk the existing variables to the first free byte.
        var offset = (headerLength + 28 + 3) & ~3
        while offset + variableHeaderSize <= storeEnd, image[offset] == 0xAA, image[offset + 1] == 0x55 {
            let nameSize = Int(image[offset + 36]) | Int(image[offset + 37]) << 8 | Int(image[offset + 38]) << 16 | Int(image[offset + 39]) << 24
            let dataSize = Int(image[offset + 40]) | Int(image[offset + 41]) << 8 | Int(image[offset + 42]) << 16 | Int(image[offset + 43]) << 24
            let name = String(decoding: stride(from: 0, to: nameSize - 2, by: 2).map { UInt16(image[offset + 60 + $0]) | UInt16(image[offset + 61 + $0]) << 8 }, as: UTF16.self)
            if image[offset + 2] == 0x3F, ["PK", "KEK", "db"].contains(name) {
                throw VitrineError.invalidConfig("\(varsFile.lastPathComponent) already has Secure Boot keys")
            }
            offset = (offset + variableHeaderSize + nameSize + dataSize + 3) & ~3
        }
        let auth = nonVolatile | bootService | runtime | timeBasedAuthenticatedWrite
        let decode = { (c: MicrosoftSecureBootCerts.Certificate) in Data(base64Encoded: c.der)! }
        var vars = Data()
        vars += variable(name: "PK", vendor: globalVariableGuid, attributes: auth,
                         data: signatureLists([platformKey], owner: guid("6a7e3b2c-1f4d-4e5a-9b8c-7d6e5f4a3b2c")), time: time)
        vars += variable(name: "KEK", vendor: globalVariableGuid, attributes: auth,
                         data: signatureLists(MicrosoftSecureBootCerts.kek.map(decode), owner: microsoftOwnerGuid), time: time)
        vars += variable(name: "db", vendor: imageSecurityDatabaseGuid, attributes: auth,
                         data: signatureLists(MicrosoftSecureBootCerts.db.map(decode), owner: microsoftOwnerGuid), time: time)
        vars += variable(name: "SecureBootEnable", vendor: secureBootEnableGuid, attributes: nonVolatile | bootService, data: Data([1]), time: time)
        vars += variable(name: "CustomMode", vendor: customModeGuid, attributes: nonVolatile | bootService, data: Data([0]), time: time)
        guard offset + vars.count <= storeEnd, image[offset..<offset + vars.count].allSatisfy({ $0 == 0xFF }) else {
            throw VitrineError.io("no room for Secure Boot keys in \(varsFile.lastPathComponent)")
        }
        image.replaceSubrange(offset..<offset + vars.count, with: vars)
        try image.write(to: varsFile, options: .atomic)
    }

    /// A self-signed platform key certificate for one VM (its private key is thrown away: nobody
    /// can change this VM's keys later except by resetting its variable store).
    public static func makePlatformKey(commonName: String) throws -> Data {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-pk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "36500",
                       "-subj", "/CN=\(commonName.replacingOccurrences(of: "/", with: "-"))",
                       "-keyout", dir.appendingPathComponent("pk.key").path,
                       "-outform", "DER", "-out", dir.appendingPathComponent("pk.der").path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw VitrineError.io("openssl could not create a platform key") }
        return try Data(contentsOf: dir.appendingPathComponent("pk.der"))
    }
}
