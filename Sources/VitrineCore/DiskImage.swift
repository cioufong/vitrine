import Foundation
#if canImport(DiskImageKit)
import DiskImageKit
#endif

public enum DiskImageFormat: String, Codable, Sendable, CaseIterable {
    /// Sparse raw file on APFS. Works everywhere.
    case raw
    /// Apple Sparse Image Format (macOS 26+). Dense on-disk layout, near-native throughput, cheap to copy.
    case asif
}

public enum DiskImage {
    /// Best format available on this host.
    public static var preferredFormat: DiskImageFormat {
        if #available(macOS 26, *) { return .asif }
        return .raw
    }

    /// Creates an empty disk image of `sizeBytes`. Returns the format actually written.
    @discardableResult
    public static func create(at url: URL, sizeBytes: UInt64, format: DiskImageFormat = preferredFormat) throws -> DiskImageFormat {
        if FileManager.default.fileExists(atPath: url.path) {
            throw VitrineError.io("disk image \(url.path) already exists")
        }
        guard sizeBytes >= 1 << 20 else { throw VitrineError.invalidConfig("disk must be at least 1 MiB") }
        if format == .asif, (try? createASIF(at: url, sizeBytes: sizeBytes)) == true {
            return .asif
        }
        try? FileManager.default.removeItem(at: url)
        try createRaw(at: url, sizeBytes: sizeBytes)
        return .raw
    }

    /// Detects the format from the file header.
    public static func format(of url: URL) -> DiskImageFormat {
        guard let h = try? FileHandle(forReadingFrom: url) else { return .raw }
        defer { try? h.close() }
        let magic = (try? h.read(upToCount: 4)) ?? Data()
        return magic == Data("shdw".utf8) ? .asif : .raw
    }

    private static func createASIF(at url: URL, sizeBytes: UInt64) throws -> Bool {
        #if canImport(DiskImageKit)
        if #available(macOS 27, *) {
            let blockSize = DiskImageKit.DiskImage.BlockSize.bytes512
            let blocks = Int((sizeBytes + UInt64(blockSize.rawValue) - 1) / UInt64(blockSize.rawValue))
            _ = try DiskImageKit.DiskImage(creating: ASIFCreationConfiguration.asif(url: url, blockCount: blocks, blockSize: blockSize))
            return true
        }
        #endif
        if #available(macOS 26, *) {
            let status = try runTool("/usr/sbin/diskutil",
                                     ["image", "create", "blank", "--fs", "None", "--format", "ASIF",
                                      "--size", "\(sizeBytes)", url.path])
            return status == 0 && FileManager.default.fileExists(atPath: url.path)
        }
        return false
    }

    /// Grows an image. Shrinking is refused to avoid data loss.
    public static func resize(at url: URL, to sizeBytes: UInt64) throws {
        switch format(of: url) {
        case .raw:
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let current = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            guard sizeBytes >= current else { throw VitrineError.invalidConfig("refusing to shrink disk image") }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: sizeBytes)
        case .asif:
            let status = try runTool("/usr/sbin/diskutil", ["image", "resize", "--size", "\(sizeBytes)", url.path])
            if status != 0 { throw VitrineError.io("diskutil image resize failed (\(status))") }
        }
    }

    static func createRaw(at url: URL, sizeBytes: UInt64) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw VitrineError.io("cannot create \(url.path)")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: sizeBytes)
    }

    /// The capacity the guest sees (not the space used on the Mac).
    public static func virtualSize(of url: URL) -> UInt64? {
        switch format(of: url) {
        case .raw:
            return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64
        case .asif:
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            p.arguments = ["image", "info", url.path]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            return text.split(separator: "\n")
                .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Total Bytes:") }
                .flatMap { UInt64($0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") }
        }
    }

    /// Bytes actually allocated on disk (sparse-aware).
    public static func allocatedSize(of url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return UInt64(values?.totalFileAllocatedSize ?? 0)
    }

    /// True when a raw disk has no partition table yet (no MBR/protective-MBR signature).
    public static func isBlank(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let sector = try? h.read(upToCount: 512), sector.count == 512 else { return true }
        return !(sector[510] == 0x55 && sector[511] == 0xAA)
    }

    /// True for a UDIF disk image (`hdiutil` .dmg), which ends in a 512-byte "koly" trailer.
    public static func isUDIF(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let end = try? h.seekToEnd(), end >= 512, (try? h.seek(toOffset: end - 512)) != nil,
              let magic = try? h.read(upToCount: 4) else { return false }
        return magic == Data("koly".utf8)
    }

    /// Copy-on-write clone (APFS `clonefile`). Instant and initially free; falls back to a copy off-APFS.
    public static func clone(_ src: URL, to dst: URL) throws {
        if clonefile(src.path, dst.path, 0) == 0 { return }
        let err = errno
        if err == EXDEV || err == ENOTSUP {
            try FileManager.default.copyItem(at: src, to: dst)
            return
        }
        throw VitrineError.io("clonefile \(src.lastPathComponent) failed: \(String(cString: strerror(err)))")
    }
}

@discardableResult
func runTool(_ path: String, _ args: [String]) throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

public extension UInt64 {
    /// Parses sizes like "64G", "512M", "1.5T", "64GB", "64GiB", "1048576".
    init?(sizeString: String) {
        var s = sizeString.trimmingCharacters(in: .whitespaces).uppercased()
        for suffix in ["IB", "B"] where s.hasSuffix(suffix) && s.count > suffix.count {
            let stripped = String(s.dropLast(suffix.count))
            if let last = stripped.last, "KMGT".contains(last) { s = stripped; break }
        }
        guard let last = s.last else { return nil }
        let multipliers: [Character: Double] = ["K": 0x1p10, "M": 0x1p20, "G": 0x1p30, "T": 0x1p40]
        if let m = multipliers[last] {
            guard let v = Double(s.dropLast()), v.isFinite, v > 0 else { return nil }
            let bytes = v * m
            guard bytes < 0x1p63 else { return nil }
            self = UInt64(bytes)
        } else {
            guard let v = UInt64(s), v > 0 else { return nil }
            self = v
        }
    }
}

public func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
}
