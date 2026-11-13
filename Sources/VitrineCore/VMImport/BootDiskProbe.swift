import Foundation

/// Reads a disk's partition table (MBR, GPT, hybrid) and the EFI system partition's FAT file
/// system far enough to list its boot loaders. Vitrine boots everything with UEFI, so whether a
/// disk from another tool can boot here depends on what is on it, not on its old VM's firmware
/// setting. All reads go through `read(offset, length)` (the guest-visible disk), and are bounded.
public enum BootDiskProbe {
    public struct Result: Codable, Sendable, Equatable {
        public enum Scheme: String, Codable, Sendable { case gpt, mbr, none }
        public var scheme: Scheme
        public var sectorSize: Int = 512
        /// An EFI system partition was found (GPT type C12A7328-…, or MBR type 0xEF).
        public var hasESP = false
        /// The ESP's offset in bytes.
        public var espOffset: UInt64?
        /// A GPT "BIOS boot" partition, or MBR partitions besides a protective one (a hybrid disk
        /// that also boots with BIOS).
        public var hasBIOSBoot = false
        /// Removable-media loaders in EFI/BOOT (upper-cased 8.3 names: "BOOTAA64.EFI", "BOOTX64.EFI").
        public var fallbackLoaders: [String] = []
        /// Folders in EFI/ other than BOOT ("DEBIAN", "MICROSOFT", …).
        public var vendorFolders: [String] = []
        /// Why the ESP couldn't be read, if it couldn't.
        public var espError: String?

        public var architecture: VMConfig.Architecture? {
            let arm = fallbackLoaders.contains("BOOTAA64.EFI"), x86 = fallbackLoaders.contains("BOOTX64.EFI")
            if arm && !x86 { return .aarch64 }
            if x86 && !arm { return .x86_64 }
            return nil
        }
        public var looksLikeWindows: Bool { vendorFolders.contains("MICROSOFT") }

        public var summary: String {
            var s: String
            switch scheme {
            case .gpt: s = "GPT"
            case .mbr: s = "MBR"
            case .none: return "no partition table"
            }
            s += hasESP ? ", EFI system partition" : ", no EFI system partition"
            if hasBIOSBoot { s += ", also BIOS-bootable" }
            if !fallbackLoaders.isEmpty { s += ", EFI/BOOT/" + fallbackLoaders.joined(separator: " + ") }
            else if hasESP && espError == nil { s += ", no EFI/BOOT fallback loader" }
            if !vendorFolders.isEmpty { s += ", EFI/{" + vendorFolders.joined(separator: ",").lowercased() + "}" }
            if let e = espError { s += " (ESP unreadable: \(e))" }
            return s
        }
    }

    public typealias Reader = (_ offset: UInt64, _ length: Int) throws -> Data

    static let espGUID: [UInt8] = [0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11, 0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B]
    static let biosBootGUID: [UInt8] = [0x48, 0x61, 0x68, 0x21, 0x49, 0x64, 0x6F, 0x6E, 0x74, 0x4E, 0x65, 0x65, 0x64, 0x45, 0x46, 0x49]

    public static func probe(diskSize: UInt64, read: @escaping Reader) throws -> Result {
        let head = try read(0, Int(min(diskSize, 8192)))
        // GPT: header at LBA 1, for 512- or 4096-byte sectors.
        for sector in [512, 4096] where head.count >= sector + 92 {
            if head.subdata(sector, 8) == Data("EFI PART".utf8) {
                return try gpt(head.subdata(sector, 92), sectorSize: sector, diskSize: diskSize, read: read)
            }
        }
        guard head.count >= 512, head[510] == 0x55, head[511] == 0xAA else { return Result(scheme: .none) }
        var r = Result(scheme: .mbr)
        for i in 0..<4 {
            let e = 446 + i * 16
            let type = head[e + 4]
            let start = UInt64(head.u32(e + 8)) * 512
            guard type != 0 else { continue }
            if type == 0xEF, !r.hasESP {
                r.hasESP = true
                r.espOffset = start
            } else if type != 0xEE {
                r.hasBIOSBoot = true
            }
        }
        if let off = r.espOffset { readESP(&r, offset: off, read: read) }
        return r
    }

    static func gpt(_ header: Data, sectorSize: Int, diskSize: UInt64, read: @escaping Reader) throws -> Result {
        var r = Result(scheme: .gpt, sectorSize: sectorSize)
        let entriesLBA = header.u64(72), count = Int(header.u32(80)), size = Int(header.u32(84))
        guard (1...1024).contains(count), (128...4096).contains(size), size % 8 == 0,
              entriesLBA < diskSize / UInt64(sectorSize) else {
            r.espError = "malformed GPT header"
            return r
        }
        let table = try read(entriesLBA * UInt64(sectorSize), min(count * size, 1 << 20))
        var i = 0
        while (i + 1) * size <= table.count {
            let e = table.subdata(i * size, size)
            i += 1
            let type = [UInt8](e.prefix(16))
            if type == espGUID, !r.hasESP {
                r.hasESP = true
                r.espOffset = e.u64(32) * UInt64(sectorSize)
            } else if type == biosBootGUID {
                r.hasBIOSBoot = true
            }
        }
        if let off = r.espOffset {
            if off >= diskSize { r.espError = "partition starts past the end of the disk" }
            else { readESP(&r, offset: off, read: read) }
        }
        return r
    }

    // MARK: FAT

    static func readESP(_ r: inout Result, offset: UInt64, read: @escaping Reader) {
        do {
            let fat = try FAT(offset: offset, read: read)
            guard let efi = try fat.find("EFI", in: fat.root) else { r.espError = nil; return }
            for entry in try fat.list(efi) where entry.isDirectory {
                if entry.name == "BOOT" {
                    r.fallbackLoaders = try fat.list(entry).filter { !$0.isDirectory && $0.name.hasPrefix("BOOT") && $0.name.hasSuffix(".EFI") }
                        .map { $0.name }.sorted()
                } else if entry.name != "." && entry.name != ".." {
                    r.vendorFolders.append(entry.name)
                }
            }
            r.vendorFolders.sort()
        } catch {
            r.espError = (error as? FAT.Failure)?.reason ?? "\(error)"
        }
    }

    struct FAT {
        struct Failure: Error { var reason: String }
        struct Entry { var name: String; var isDirectory: Bool; var cluster: UInt32 }
        enum Kind { case fat12, fat16, fat32 }

        let base: UInt64, read: Reader
        let bytesPerSector: Int, sectorsPerCluster: Int, kind: Kind
        let fatOffset: UInt64, rootOffset: UInt64, rootBytes: Int, dataOffset: UInt64, clusterCount: UInt32
        let root: Entry

        init(offset: UInt64, read: @escaping Reader) throws {
            base = offset
            self.read = read
            let bs = try read(offset, 512)
            guard bs.count == 512, bs[510] == 0x55, bs[511] == 0xAA else { throw Failure(reason: "not a FAT file system") }
            bytesPerSector = Int(bs.u16(11))
            sectorsPerCluster = Int(bs[13])
            let reserved = UInt64(bs.u16(14)), fats = UInt64(bs[16]), rootEntries = Int(bs.u16(17))
            let total = bs.u16(19) != 0 ? UInt64(bs.u16(19)) : UInt64(bs.u32(32))
            let fatSize = bs.u16(22) != 0 ? UInt64(bs.u16(22)) : UInt64(bs.u32(36))
            guard [512, 1024, 2048, 4096].contains(bytesPerSector), sectorsPerCluster > 0,
                  sectorsPerCluster & (sectorsPerCluster - 1) == 0, reserved > 0, (1...4).contains(fats), fatSize > 0 else {
                throw Failure(reason: "not a FAT file system")
            }
            let bps = UInt64(bytesPerSector)
            rootBytes = rootEntries * 32
            let rootSectors = (UInt64(rootBytes) + bps - 1) / bps
            let dataStart = reserved + fats * fatSize + rootSectors
            guard total > dataStart else { throw Failure(reason: "FAT geometry is inconsistent") }
            clusterCount = UInt32(min((total - dataStart) / UInt64(sectorsPerCluster), UInt64(UInt32.max)))
            kind = clusterCount < 4085 ? .fat12 : clusterCount < 65525 ? .fat16 : .fat32
            fatOffset = offset + reserved * bps
            rootOffset = offset + (reserved + fats * fatSize) * bps
            dataOffset = offset + dataStart * bps
            root = Entry(name: "/", isDirectory: true, cluster: kind == .fat32 ? bs.u32(44) : 0)
        }

        var clusterBytes: Int { bytesPerSector * sectorsPerCluster }

        func next(_ cluster: UInt32) throws -> UInt32? {
            switch kind {
            case .fat32:
                let v = try read(fatOffset + UInt64(cluster) * 4, 4).u32(0) & 0x0FFF_FFFF
                return v >= 2 && v < 0x0FFF_FFF7 ? v : nil
            case .fat16:
                let v = UInt32(try read(fatOffset + UInt64(cluster) * 2, 2).u16(0))
                return v >= 2 && v < 0xFFF7 ? v : nil
            case .fat12:
                let off = UInt64(cluster) + UInt64(cluster) / 2
                let w = UInt32(try read(fatOffset + off, 2).u16(0))
                let v = cluster & 1 == 1 ? w >> 4 : w & 0xFFF
                return v >= 2 && v < 0xFF7 ? v : nil
            }
        }

        /// A directory's raw bytes: at most 64 clusters (bounded; boot folders hold a few files).
        func contents(_ dir: Entry) throws -> Data {
            if dir.cluster == 0 { // FAT12/16 root
                guard kind != .fat32 else { throw Failure(reason: "bad root cluster") }
                return try read(rootOffset, min(rootBytes, 1 << 20))
            }
            var out = Data(), cluster = dir.cluster, seen = Set<UInt32>()
            while out.count < 64 * clusterBytes {
                guard cluster >= 2, cluster < clusterCount + 2, seen.insert(cluster).inserted else { break }
                out += try read(dataOffset + UInt64(cluster - 2) * UInt64(clusterBytes), clusterBytes)
                guard let n = try next(cluster) else { break }
                cluster = n
            }
            return out
        }

        func list(_ dir: Entry) throws -> [Entry] {
            let data = try contents(dir)
            var entries: [Entry] = []
            var off = 0
            var longName: [Int: [UInt16]] = [:] // VFAT long-name pieces by sequence number
            while off + 32 <= data.count {
                defer { off += 32 }
                let first = data[data.startIndex + off]
                if first == 0 { break }
                let attr = data[data.startIndex + off + 11]
                if first == 0xE5 { longName = [:]; continue } // deleted
                if attr & 0x3F == 0x0F { // a long-name piece: 13 UTF-16 units
                    let seq = Int(first & 0x1F)
                    var units: [UInt16] = []
                    for o in [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30] { units.append(data.u16(off + o)) }
                    if first & 0x40 != 0 { longName = [:] }
                    longName[seq] = units
                    continue
                }
                defer { longName = [:] }
                if attr & 0x08 != 0 { continue } // volume label
                let raw = [UInt8](data.subdata(off, 11))
                func part(_ s: ArraySlice<UInt8>) -> String {
                    String(decoding: s, as: UTF8.self).trimmingCharacters(in: .whitespaces).uppercased()
                }
                let stem = part(raw[0..<8]), ext = part(raw[8..<11])
                var name = ext.isEmpty ? stem : "\(stem).\(ext)"
                if !longName.isEmpty {
                    let units = longName.keys.sorted().flatMap { longName[$0]! }.prefix { $0 != 0 && $0 != 0xFFFF }
                    let long = String(decoding: Array(units), as: UTF16.self)
                    if !long.isEmpty { name = long.uppercased() }
                }
                let cluster = UInt32(data.u16(off + 20)) << 16 | UInt32(data.u16(off + 26))
                entries.append(Entry(name: name, isDirectory: attr & 0x10 != 0, cluster: cluster))
            }
            return entries
        }

        func find(_ name: String, in dir: Entry) throws -> Entry? {
            try list(dir).first { $0.isDirectory && $0.name == name }
        }
    }
}

extension Data {
    func subdata(_ offset: Int, _ length: Int) -> Data {
        let start = startIndex + offset
        let end = Swift.min(start + length, endIndex)
        return start < end ? subdata(in: start..<end) : Data()
    }
    func u16(_ o: Int) -> UInt16 {
        guard o + 2 <= count else { return 0 }
        let i = startIndex + o
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }
    func u32(_ o: Int) -> UInt32 {
        guard o + 4 <= count else { return 0 }
        let i = startIndex + o
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
    func u64(_ o: Int) -> UInt64 { UInt64(u32(o)) | UInt64(u32(o + 4)) << 32 }
}
