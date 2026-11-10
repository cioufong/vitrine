import Foundation
import XCTest
@testable import VitrineVZ
@testable import VitrineCore
@testable import VitrineQEMU

/// Whole-VM import (OVA/OVF, VMware, Parallels, VirtualBox): the configuration parsers on the real
/// configurations in Fixtures/VMImport (trimmed copies, no disks), synthetic boot disks built here,
/// and hostile inputs.
final class WholeVMImportTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private var savedHome: String?
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/VMImport")

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("vitrine-vmimport-\(UUID())").resolvingSymlinksInPath()
        try fm.createDirectory(at: root.appendingPathComponent("library"), withIntermediateDirectories: true)
        savedHome = ProcessInfo.processInfo.environment["VITRINE_HOME"]
        setenv("VITRINE_HOME", root.appendingPathComponent("library").path, 1)
    }

    override func tearDownWithError() throws {
        if let savedHome { setenv("VITRINE_HOME", savedHome, 1) } else { unsetenv("VITRINE_HOME") }
        try? fm.removeItem(at: root)
    }

    // MARK: Helpers

    private func requireQemuImg() throws {
        guard DiskImport.isQemuImgAvailable else { throw XCTSkip("qemu-img not installed") }
    }

    private func qemuImg(_ args: [String]) throws {
        let p = Process()
        p.executableURL = try DiskImport.qemuImg()
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "qemu-img \(args)")
    }

    private func dir(_ name: String) throws -> URL {
        let d = root.appendingPathComponent(name)
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func fixture(_ path: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(path)) }

    enum Layout { case gpt, mbrESP, mbrBIOS, blank }

    /// An 8 MiB raw disk: a partition table and, unless BIOS-only, a FAT12 EFI system partition at
    /// 1 MiB holding EFI/BOOT/<loader> and EFI/DEBIAN.
    static func bootDisk(_ layout: Layout, loader: String? = "BOOTAA64EFI", vendor: String = "DEBIAN") -> Data {
        var d = Data(count: 8 << 20)
        func put(_ bytes: [UInt8], at o: Int) { d.replaceSubrange(o..<(o + bytes.count), with: bytes) }
        func put16(_ v: UInt16, at o: Int) { put([UInt8(v & 0xFF), UInt8(v >> 8)], at: o) }
        func put32(_ v: UInt32, at o: Int) { put((0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) }, at: o) }
        func name(_ s: String) -> [UInt8] { Array(s.padding(toLength: 11, withPad: " ", startingAt: 0).utf8) }
        if layout == .blank { return d }
        put([0x55, 0xAA], at: 510)
        let espLBA: UInt32 = 2048, espSectors: UInt32 = 4096
        switch layout {
        case .gpt:
            put([0, 0, 0, 0, 0xEE], at: 446); put32(1, at: 446 + 8); put32(16383, at: 446 + 12)
            put(Array("EFI PART".utf8), at: 512)
            put32(92, at: 512 + 12)
            put32(2, at: 512 + 72); put32(128, at: 512 + 80); put32(128, at: 512 + 84)
            put(BootDiskProbe.espGUID, at: 1024)
            put32(espLBA, at: 1024 + 32); put32(espLBA + espSectors - 1, at: 1024 + 40)
        case .mbrESP:
            put([0, 0, 0, 0, 0xEF], at: 446); put32(espLBA, at: 446 + 8); put32(espSectors, at: 446 + 12)
        case .mbrBIOS:
            put([0x80, 0, 0, 0, 0x83], at: 446); put32(espLBA, at: 446 + 8); put32(espSectors, at: 446 + 12)
            return d
        case .blank: break
        }
        // FAT12: 512-byte sectors, 4 per cluster, 1 reserved, 2 FATs of 3 sectors, 512 root entries.
        let b = Int(espLBA) * 512
        put([0xEB, 0x3C, 0x90], at: b); put(Array("MSDOS5.0".utf8), at: b + 3)
        put16(512, at: b + 11); put([4], at: b + 13); put16(1, at: b + 14); put([2], at: b + 16)
        put16(512, at: b + 17); put16(UInt16(espSectors), at: b + 19); put([0xF8], at: b + 21); put16(3, at: b + 22)
        put([0x55, 0xAA], at: b + 510)
        let rootDir = b + 7 * 512, data = b + 39 * 512, cluster = 4 * 512
        func entry(_ at: Int, _ n: String, dir: Bool, cluster c: UInt16) {
            put(name(n), at: at); put([dir ? 0x10 : 0x20], at: at + 11); put16(c, at: at + 26)
        }
        entry(rootDir, "EFI", dir: true, cluster: 2)
        entry(data, ".", dir: true, cluster: 2)
        entry(data + 32, "..", dir: true, cluster: 0)
        entry(data + 64, "BOOT", dir: true, cluster: 3)
        if vendor.count > 8 { // a VFAT long name ("Microsoft") before its 8.3 alias
            var lfn = [UInt8](repeating: 0xFF, count: 32)
            lfn[0] = 0x41; lfn[11] = 0x0F; lfn[12] = 0; lfn[26] = 0; lfn[27] = 0
            let units = Array(vendor.utf16) + [0]
            for (i, o) in [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30].enumerated() where i < units.count {
                lfn[o] = UInt8(units[i] & 0xFF); lfn[o + 1] = UInt8(units[i] >> 8)
            }
            put(lfn, at: data + 96)
            entry(data + 128, String(vendor.uppercased().prefix(6)) + "~1", dir: true, cluster: 4)
        } else {
            entry(data + 96, vendor, dir: true, cluster: 4)
        }
        if let loader { entry(data + cluster, loader, dir: false, cluster: 5) }
        return d
    }

    /// `raw` written as `format` at `url`.
    private func image(_ raw: Data, format: String, at url: URL, options: [String] = []) throws {
        let tmp = root.appendingPathComponent("src-\(UUID()).raw")
        try raw.write(to: tmp)
        if format == "raw" { try fm.moveItem(at: tmp, to: url); return }
        try qemuImg(["convert", "-f", "raw", "-O", format] + options + [tmp.path, url.path])
        try fm.removeItem(at: tmp)
    }

    /// A ustar archive of (name, data, typeflag) members.
    static func tar(_ members: [(String, Data, UInt8)]) -> Data {
        var out = Data()
        for (name, data, type) in members {
            var h = Data(count: 512)
            func put(_ s: String, _ o: Int) { let b = Array(s.utf8); h.replaceSubrange(o..<(o + b.count), with: b) }
            put(name, 0)
            put("0000644\0", 100); put("0000000\0", 108); put("0000000\0", 116)
            put(String(format: "%011o\0", data.count), 124)
            put(String(format: "%011o\0", 0), 136)
            h[156] = type
            put("ustar\0", 257); put("00", 263)
            put("        ", 148)
            let sum = h.reduce(0) { $0 + Int($1) }
            put(String(format: "%06o\0 ", sum), 148)
            out += h + data + Data(count: (512 - data.count % 512) % 512)
        }
        return out + Data(count: 1024)
    }

    /// A sparse-VMDK header with capacity 0, which makes qemu read the embedded descriptor's extents.
    static func embeddedDescriptorVMDK(extent: String) -> Data {
        var h = Data(count: 512)
        func put64(_ v: UInt64, _ o: Int) { for i in 0..<8 { h[o + i] = UInt8((v >> (8 * UInt64(i))) & 0xFF) } }
        h.replaceSubrange(0..<4, with: Array("KDMV".utf8))
        h[4] = 1; h[8] = 3
        put64(0, 12); put64(128, 20); put64(1, 28); put64(1, 36)
        h.replaceSubrange(73..<77, with: [0x0A, 0x20, 0x0D, 0x0A])
        var desc = Data("# Disk DescriptorFile\nversion=1\nCID=fffffffe\nparentCID=ffffffff\ncreateType=\"monolithicFlat\"\nRW 16 FLAT \"\(extent)\" 0\n".utf8)
        desc += Data(count: 512 - desc.count)
        return h + desc
    }

    static func sha256(_ d: Data) -> String {
        var h = ImportHasher(.sha256); h.update(d); return h.finalize()
    }

    /// A VMware folder: the bento Debian .vmx (fixture) and `disk.vmdk` from `raw`.
    private func vmwareFolder(_ raw: Data, vmx: Data? = nil) throws -> URL {
        let d = try dir("deb.vmwarevm")
        try (vmx ?? fixture("vmware/debian-12.12-aarch64.vmx")).write(to: d.appendingPathComponent("debian.vmx"))
        try image(raw, format: "vmdk", at: d.appendingPathComponent("disk.vmdk"))
        return d
    }

    // MARK: Names and paths

    func testNamesAreSanitisedBeforeAnyPathIsBuilt() throws {
        XCTAssertEqual(VMImportName.sanitize("../../x"), "x")
        XCTAssertEqual(VMImportName.sanitize("Photon OS"), "Photon-OS")
        XCTAssertEqual(VMImportName.sanitize("Windows 11 (ARM)"), "Windows-11-ARM")
        XCTAssertEqual(VMImportName.sanitize(".hidden"), "hidden")
        XCTAssertEqual(VMImportName.sanitize("日本語"), "Imported-VM")
        XCTAssertEqual(VMImportName.sanitize("..."), "Imported-VM")
        XCTAssertEqual(VMImportName.sanitize(String(repeating: "a", count: 100)).count, 64)
        XCTAssertThrowsError(try VMImportName.resolve(explicit: "../evil", derived: "ok"))
        XCTAssertEqual(try VMImportName.resolve(explicit: nil, derived: "a/b"), "a-b")
    }

    func testUTMNameFromConfigCannotLeaveTheLibrary() throws {
        let utm = root.appendingPathComponent("Evil.utm")
        try fm.createDirectory(at: utm.appendingPathComponent("Data"), withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Backend": "Apple", "ConfigurationVersion": 4, "Information": ["Name": "../../escaped"],
            "System": ["CPUCount": 2, "MemorySize": 2048, "Boot": ["OperatingSystem": "Linux", "UEFIBoot": true]],
            "Drive": [["ImageName": "d.img"]],
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: utm.appendingPathComponent("config.plist"))
        try Data(count: 4096).write(to: utm.appendingPathComponent("Data/d.img"))
        let r = try UTMImporter.importVM(utm, name: nil)
        XCTAssertEqual(r.bundle.name, "escaped")
        XCTAssertEqual(r.bundle.url.deletingLastPathComponent().path, VMLibrary.root.path)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("escaped.vitrinevm").path))
        XCTAssertThrowsError(try UTMImporter.importVM(utm, name: "../x"))
    }

    func testDiskImportRefusesAnInvalidName() {
        XCTAssertThrowsError(try VMImporter.importDisk(root.appendingPathComponent("x.img"), .init(name: "../../x"))) { e in
            XCTAssertTrue("\(e)".contains("not a valid VM name"))
        }
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("x.vitrinevm").path))
    }

    func testReferencedPathsMustStayInsideTheSource() throws {
        let src = try dir("vm")
        try fm.createDirectory(at: src.appendingPathComponent("sub"), withIntermediateDirectories: true)
        XCTAssertEqual(ImportPath.resolve("disk.vmdk", base: src, root: src)?.lastPathComponent, "disk.vmdk")
        XCTAssertEqual(ImportPath.resolve("sub\\disk.vdi", base: src, root: src)?.path, ImportPath.realPath(src.appendingPathComponent("sub/disk.vdi").path))
        for bad in ["/vmfs/volumes/x/disk.vmdk", "../disk.vmdk", "sub/../../disk.vmdk", "..\\..\\etc\\passwd",
                    "C:/Users/x/disk.vdi", "C:\\Users\\x.vdi", "\\\\server\\share\\x.vmdk", "~/x.vmdk", "", "a\0b",
                    "file:///etc/hosts"] {
            XCTAssertNil(ImportPath.resolve(bad, base: src, root: src), bad)
        }
        // An absolute path is fine if it points inside the folder.
        XCTAssertNotNil(ImportPath.resolve(src.appendingPathComponent("disk.vmdk").path, base: src, root: src))
        // A symlink inside the folder pointing out of it.
        try fm.createSymbolicLink(at: src.appendingPathComponent("link.vmdk"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertNil(ImportPath.resolve("link.vmdk", base: src, root: src))
        try fm.createSymbolicLink(at: src.appendingPathComponent("up"), withDestinationURL: root)
        XCTAssertNil(ImportPath.resolve("up/other.vmdk", base: src, root: src))
    }

    func testMACAddressesAreNormalised() {
        XCTAssertEqual(WholeVMImporter.normalizeMAC("001C426BB594"), "00:1c:42:6b:b5:94")
        XCTAssertEqual(WholeVMImporter.normalizeMAC("00-0C-29-99-F1-14"), "00:0c:29:99:f1:14")
        XCTAssertEqual(WholeVMImporter.normalizeMAC("52:54:00:06:12:af"), "52:54:00:06:12:af")
        XCTAssertNil(WholeVMImporter.normalizeMAC("%MACAddress%"))
        XCTAssertNil(WholeVMImporter.normalizeMAC("01:00:5e:00:00:01"), "multicast")
        XCTAssertNil(WholeVMImporter.normalizeMAC("52:54:00:aa:bb:cc,id=x"))
    }

    // MARK: Parsers

    func testXMLWithADoctypeIsRefused() {
        let xxe = Data("""
        <?xml version="1.0"?>
        <!DOCTYPE Envelope [ <!ENTITY xxe SYSTEM "file:///etc/passwd"> ]>
        <Envelope><VirtualSystem><Name>&xxe;</Name></VirtualSystem></Envelope>
        """.utf8)
        XCTAssertThrowsError(try ImportXML.parse(xxe, what: "test")) { XCTAssertTrue("\($0)".contains("document type")) }
        let bomb = Data("<!DOCTYPE a [<!ENTITY a \"aaaa\"><!ENTITY b \"&a;&a;&a;\">]><a>&b;</a>".utf8)
        XCTAssertThrowsError(try ImportXML.parse(bomb, what: "test"))
        // The same payload in UTF-16, where a byte search for "<!DOCTYPE" finds nothing.
        let utf16 = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><!DOCTYPE a [<!ENTITY a \"aaaa\">]><a>&a;</a>".data(using: .utf16)!
        XCTAssertThrowsError(try ImportXML.parse(utf16, what: "test"))
        XCTAssertThrowsError(try ImportXML.parse(utf16.dropFirst(2), what: "test")) // no BOM
        XCTAssertNoThrow(try ImportXML.parse(Data("<a b=\"1\"><c>x</c></a>".utf8), what: "test"))
    }

    func testXXEInAnOVFIsRefusedByInspect() throws {
        let d = try dir("xxe")
        try Data("""
        <?xml version="1.0"?>
        <!DOCTYPE Envelope [ <!ENTITY xxe SYSTEM "file:///etc/passwd"> ]>
        <Envelope xmlns="http://schemas.dmtf.org/ovf/envelope/1"><VirtualSystem><Name>&xxe;</Name></VirtualSystem></Envelope>
        """.utf8).write(to: d.appendingPathComponent("x.ovf"))
        XCTAssertThrowsError(try WholeVMImporter.inspect(d.appendingPathComponent("x.ovf")))
    }

    func testVMXKeysEncodingAndEscapes() throws {
        var text = Data(".encoding = \"windows-1252\"\nDisplayName = \"Caf".utf8)
        text.append(0xE9) // é in windows-1252
        text.append(Data(" |22quoted|22\"\nSATA0:0.FileName = \"disk.vmdk\"\n# comment\nmemSize=\"2048\"\n".utf8))
        let v = try VMXFile(data: text)
        XCTAssertEqual(v["displayname"], "Café \"quoted\"")
        XCTAssertEqual(v["sata0:0.filename"], "disk.vmdk")
        XCTAssertEqual(v["MEMSIZE"], "2048")
    }

    func testVMDKDescriptorParsing() {
        let d = VMDKDescriptor(data: Data("""
        # Disk DescriptorFile
        version=1
        CID=a3b18903
        parentCID=ffffffff
        createType="twoGbMaxExtentSparse"
        RW 8323072 SPARSE "disk-s001.vmdk"
        RW 1048576 FLAT "/etc/hosts" 0
        RW 100 ZERO
        """.utf8))
        XCTAssertEqual(d?.extents.map(\.file), ["disk-s001.vmdk", "/etc/hosts", nil])
        XCTAssertEqual(d?.hasParent, false)
        let child = VMDKDescriptor(data: Data("# Disk DescriptorFile\nparentCID=12345678\nparentFileNameHint=\"base.vmdk\"\nRW 1 SPARSE \"c.vmdk\"\n".utf8))
        XCTAssertEqual(child?.hasParent, true)
        XCTAssertNil(VMDKDescriptor(data: Data("KDMV".utf8) + Data(count: 508)))
    }

    func testManifestForms() throws {
        let m = try OVFManifest.parse(Data("""
        SHA256(a.ovf)= \(String(repeating: "ab", count: 32))
        SHA1(b.vmdk)= \(String(repeating: "CD", count: 20))
        SHA512(c.vmdk)= \(String(repeating: "01", count: 64))
        """.utf8))
        XCTAssertEqual(m["a.ovf"]?.algorithm, .sha256)
        XCTAssertEqual(m["b.vmdk"]?.hex, String(repeating: "cd", count: 20))
        XCTAssertEqual(m["c.vmdk"]?.algorithm, .sha512)
        XCTAssertThrowsError(try OVFManifest.parse(Data("MD5(a)= 00".utf8)))
        XCTAssertThrowsError(try OVFManifest.parse(Data("SHA256(a)= 1234".utf8)))
    }

    func testTarListingAcceptsOnlyPlainFiles() throws {
        let ok = root.appendingPathComponent("ok.ova")
        try Self.tar([("a.ovf", Data("x".utf8), UInt8(ascii: "0")), ("b.vmdk", Data(count: 700), 0)]).write(to: ok)
        let members = try TarListing.list(ok)
        XCTAssertEqual(members.map(\.name), ["a.ovf", "b.vmdk"])
        XCTAssertEqual(members.map(\.offset), [512, 1536])
        XCTAssertEqual(members.map(\.size), [1, 700])
        let cases: [(String, [(String, Data, UInt8)])] = [
            ("dotdot", [("../evil.ovf", Data("x".utf8), UInt8(ascii: "0"))]),
            ("slash", [("sub/a.ovf", Data("x".utf8), UInt8(ascii: "0"))]),
            ("absolute", [("/etc/a.ovf", Data("x".utf8), UInt8(ascii: "0"))]),
            ("symlink", [("a.ovf", Data(), UInt8(ascii: "2"))]),
            ("hardlink", [("a.ovf", Data(), UInt8(ascii: "1"))]),
            ("device", [("a.ovf", Data(), UInt8(ascii: "3"))]),
            ("dir", [("d", Data(), UInt8(ascii: "5"))]),
            ("pax", [("PaxHeader", Data("30 path=../../etc/evil.vmdk\n".utf8), UInt8(ascii: "x"))]),
            ("gnu", [("././@LongLink", Data("x".utf8), UInt8(ascii: "L"))]),
            ("dup", [("a.ovf", Data("x".utf8), UInt8(ascii: "0")), ("a.ovf", Data("y".utf8), UInt8(ascii: "0"))]),
        ]
        for (label, entries) in cases {
            let url = root.appendingPathComponent("\(label).ova")
            try Self.tar(entries).write(to: url)
            XCTAssertThrowsError(try TarListing.list(url), label)
        }
        // Sizes of 8 GiB and more use base-256 (a sparse file stands in for the data).
        let big = root.appendingPathComponent("big.ova")
        var header = Self.tar([("disk.vmdk", Data(), UInt8(ascii: "0"))]).prefix(512)
        let size: UInt64 = 9 << 30
        header.replaceSubrange(124..<136, with: [0x80, 0, 0, 0] + (0..<8).reversed().map { UInt8((size >> (8 * UInt64($0))) & 0xFF) })
        header.replaceSubrange(148..<156, with: Array("        ".utf8))
        let sum = header.reduce(0) { $0 + Int($1) }
        header.replaceSubrange(148..<156, with: Array(String(format: "%06o\0 ", sum).utf8))
        try header.write(to: big)
        XCTAssertEqual(truncate(big.path, off_t(512 + size + 1024)), 0)
        XCTAssertEqual(try TarListing.list(big).map(\.size), [size])
        // A corrupt checksum.
        var bad = Self.tar([("a.ovf", Data("x".utf8), UInt8(ascii: "0"))])
        bad[0] = UInt8(ascii: "b")
        try bad.write(to: root.appendingPathComponent("bad.ova"))
        XCTAssertThrowsError(try TarListing.list(root.appendingPathComponent("bad.ova")))
    }

    // MARK: Boot disk probe

    func testBootDiskProbe() throws {
        func probe(_ d: Data) throws -> BootDiskProbe.Result {
            try BootDiskProbe.probe(diskSize: UInt64(d.count)) { off, len in d.subdata(Int(off), len) }
        }
        let arm = try probe(Self.bootDisk(.gpt))
        XCTAssertEqual(arm.scheme, .gpt)
        XCTAssertTrue(arm.hasESP)
        XCTAssertEqual(arm.fallbackLoaders, ["BOOTAA64.EFI"])
        XCTAssertEqual(arm.vendorFolders, ["DEBIAN"])
        XCTAssertEqual(arm.architecture, .aarch64)
        XCTAssertEqual(try probe(Self.bootDisk(.gpt, loader: "BOOTX64 EFI")).architecture, .x86_64)
        let win = try probe(Self.bootDisk(.gpt, loader: "BOOTAA64EFI", vendor: "Microsoft"))
        XCTAssertTrue(win.looksLikeWindows)
        let mbr = try probe(Self.bootDisk(.mbrESP))
        XCTAssertEqual(mbr.scheme, .mbr)
        XCTAssertEqual(mbr.fallbackLoaders, ["BOOTAA64.EFI"])
        let bios = try probe(Self.bootDisk(.mbrBIOS))
        XCTAssertEqual(bios.scheme, .mbr)
        XCTAssertFalse(bios.hasESP)
        XCTAssertTrue(bios.hasBIOSBoot)
        XCTAssertEqual(try probe(Self.bootDisk(.blank)).scheme, .none)
        let noLoader = try probe(Self.bootDisk(.gpt, loader: nil))
        XCTAssertTrue(noLoader.hasESP)
        XCTAssertEqual(noLoader.fallbackLoaders, [])
        // Garbage where the ESP should be: reported, not thrown.
        var junk = Self.bootDisk(.gpt)
        junk.replaceSubrange((1 << 20)..<((1 << 20) + 512), with: Data(repeating: 0xFF, count: 512))
        XCTAssertNotNil(try probe(junk).espError)
    }

    // MARK: VMware

    func testVMwareArmVMImportsOnVirtualizationFramework() throws {
        try requireQemuImg()
        let raw = Self.bootDisk(.gpt)
        let src = try vmwareFolder(raw)
        XCTAssertEqual(WholeVMImporter.detect(src), .vmware)
        let plan = try WholeVMImporter.inspect(src)
        XCTAssertEqual(plan.blockers, [], plan.summary)
        XCTAssertEqual(plan.name, "debian-12.12-aarch64")
        XCTAssertEqual(plan.guestOS, .linux)
        XCTAssertEqual(plan.architecture, .aarch64)
        XCTAssertEqual(plan.backend, .vz)
        XCTAssertEqual(plan.firmware, .uefi)
        XCTAssertEqual(plan.cpuCount, min(2, ProcessInfo.processInfo.processorCount))
        XCTAssertEqual(plan.memoryMiB, 4096)
        XCTAssertEqual(plan.disks.map(\.format), ["vmdk"])
        XCTAssertEqual(plan.disks.first?.virtualSize, UInt64(raw.count))
        XCTAssertTrue(plan.warnings.contains { $0.code == .nvramNotImported })
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: VMLibrary.root.path), [], "inspect writes nothing")

        let b = try WholeVMImporter.execute(plan)
        let c = try b.loadConfig()
        XCTAssertEqual(c.effectiveBackend, .vz)
        XCTAssertEqual(c.boot, .efi)
        XCTAssertEqual(c.disks.map(\.path), ["disk.img"])
        XCTAssertEqual(c.disks.first?.interface, .virtio)
        XCTAssertFalse(b.isInstalling)
        XCTAssertEqual(try Data(contentsOf: b.resolve("disk.img")), raw)
    }

    func testVMwareFixturesAreRefusedForTheRightReasons() throws {
        // Encrypted Windows 11 with a vTPM.
        let enc = try dir("enc.vmwarevm")
        try fixture("vmware/encrypted.vmx").write(to: enc.appendingPathComponent("Win11.vmx"))
        var plan = try WholeVMImporter.inspect(enc)
        XCTAssertTrue(plan.blockers.contains { $0.code == .encrypted }, plan.summary)
        XCTAssertEqual(plan.guestOS, .windows)
        XCTAssertTrue(plan.warnings.contains { $0.code == .tpmNotImported })
        // ESXi VM whose disks live on /vmfs.
        let esx = try dir("esx")
        try fixture("vmware/vmfs.vmx").write(to: esx.appendingPathComponent("CEPH0.vmx"))
        plan = try WholeVMImporter.inspect(esx.appendingPathComponent("CEPH0.vmx"))
        XCTAssertEqual(plan.blockers.filter { $0.code == .pathOutsideSource }.count, 3, plan.summary)
        XCTAssertEqual(plan.macAddress, "52:54:00:06:12:af")
        XCTAssertEqual(plan.memoryMiB, min(14336, ProcessInfo.processInfo.physicalMemory >> 20))
    }

    func testVMwareSnapshotsAndSavedStateAreRefused() throws {
        try requireQemuImg()
        let src = try vmwareFolder(Self.bootDisk(.gpt))
        try fixture("vmware/snapshots.vmsd").write(to: src.appendingPathComponent("debian.vmsd"))
        XCTAssertTrue(try WholeVMImporter.inspect(src).blockers.contains { $0.code == .snapshots })
        try fm.removeItem(at: src.appendingPathComponent("debian.vmsd"))
        var vmx = String(decoding: try fixture("vmware/debian-12.12-aarch64.vmx"), as: UTF8.self)
        vmx = vmx.replacingOccurrences(of: "checkpoint.vmstate = \"\"", with: "checkpoint.vmstate = \"debian.vmss\"")
        try Data(vmx.utf8).write(to: src.appendingPathComponent("debian.vmx"))
        XCTAssertTrue(try WholeVMImporter.inspect(src).blockers.contains { $0.code == .savedState })
        // A snapshot child disk by name.
        vmx = vmx.replacingOccurrences(of: "debian.vmss", with: "")
            .replacingOccurrences(of: "sata0:0.filename = \"disk.vmdk\"", with: "sata0:0.filename = \"disk-000001.vmdk\"")
        try Data(vmx.utf8).write(to: src.appendingPathComponent("debian.vmx"))
        try fm.copyItem(at: src.appendingPathComponent("disk.vmdk"), to: src.appendingPathComponent("disk-000001.vmdk"))
        XCTAssertTrue(try WholeVMImporter.inspect(src).blockers.contains { $0.code == .snapshots })
    }

    func testBIOSOnlyDiskIsRefused() throws {
        try requireQemuImg()
        let plan = try WholeVMImporter.inspect(vmwareFolder(Self.bootDisk(.mbrBIOS)))
        XCTAssertEqual(plan.firmware, .bios)
        XCTAssertTrue(plan.blockers.contains { $0.code == .biosOnly }, plan.summary)
        XCTAssertThrowsError(try WholeVMImporter.execute(plan))
        try fm.removeItem(at: root.appendingPathComponent("deb.vmwarevm"))
        let blank = try WholeVMImporter.inspect(vmwareFolder(Self.bootDisk(.blank)))
        XCTAssertTrue(blank.blockers.contains { $0.code == .noBootPartition }, blank.summary)
    }

    func testMissingFallbackLoaderWarns() throws {
        try requireQemuImg()
        let plan = try WholeVMImporter.inspect(vmwareFolder(Self.bootDisk(.gpt, loader: nil)))
        XCTAssertEqual(plan.blockers, [])
        XCTAssertTrue(plan.warnings.contains { $0.code == .noFallbackLoader }, plan.summary)
    }

    /// A text VMDK descriptor can name any file as an extent; it must be refused before qemu-img
    /// opens it, wherever the descriptor comes from.
    func testHostileVMDKDescriptorIsRefusedEverywhere() throws {
        try requireQemuImg()
        let hostile = Data("""
        # Disk DescriptorFile
        version=1
        CID=fffffffe
        parentCID=ffffffff
        createType="monolithicFlat"
        RW 16 FLAT "/etc/hosts" 0
        """.utf8)
        // Loose, in a VMware folder.
        let vm = try dir("hostile.vmwarevm")
        try fixture("vmware/debian-12.12-aarch64.vmx").write(to: vm.appendingPathComponent("x.vmx"))
        try hostile.write(to: vm.appendingPathComponent("disk.vmdk"))
        var plan = try WholeVMImporter.inspect(vm)
        XCTAssertTrue(plan.blockers.contains { $0.code == .pathOutsideSource }, plan.summary)
        XCTAssertEqual(plan.disks, [])
        // Relative escape.
        try Data(String(decoding: hostile, as: UTF8.self).replacingOccurrences(of: "/etc/hosts", with: "../../secret.raw").utf8)
            .write(to: vm.appendingPathComponent("disk.vmdk"))
        plan = try WholeVMImporter.inspect(vm)
        XCTAssertTrue(plan.blockers.contains { $0.code == .pathOutsideSource }, plan.summary)

        // In an OVF folder.
        let ovfDir = try dir("hostile-ovf")
        let ovf = String(decoding: try fixture("ovf/photon.ovf"), as: UTF8.self)
        try Data(ovf.utf8).write(to: ovfDir.appendingPathComponent("photon.ovf"))
        try hostile.write(to: ovfDir.appendingPathComponent("photon-disk1.vmdk"))
        plan = try WholeVMImporter.inspect(ovfDir.appendingPathComponent("photon.ovf"))
        XCTAssertTrue(plan.blockers.contains { $0.code == .pathOutsideSource }, plan.summary)

        // In an OVA: any descriptor-style member is refused.
        let ova = root.appendingPathComponent("hostile.ova")
        try Self.tar([("photon.ovf", Data(ovf.utf8), UInt8(ascii: "0")), ("photon-disk1.vmdk", hostile, UInt8(ascii: "0"))]).write(to: ova)
        plan = try WholeVMImporter.inspect(ova)
        XCTAssertTrue(plan.blockers.contains { $0.code == .diskFormat }, plan.summary)
        XCTAssertEqual(plan.disks, [])
        XCTAssertThrowsError(try WholeVMImporter.execute(plan))

        // A binary sparse header with capacity 0 and an embedded descriptor naming /etc/hosts.
        let embedded = Self.embeddedDescriptorVMDK(extent: "/etc/hosts")
        try embedded.write(to: vm.appendingPathComponent("disk.vmdk"))
        plan = try WholeVMImporter.inspect(vm)
        XCTAssertTrue(plan.blockers.contains { $0.code == .pathOutsideSource }, plan.summary)
        XCTAssertEqual(plan.disks, [])
        let ova2 = root.appendingPathComponent("hostile2.ova")
        try Self.tar([("photon.ovf", Data(ovf.utf8), UInt8(ascii: "0")), ("photon-disk1.vmdk", embedded, UInt8(ascii: "0"))]).write(to: ova2)
        plan = try WholeVMImporter.inspect(ova2)
        XCTAssertTrue(plan.blockers.contains { $0.code == .diskFormat }, plan.summary)
        XCTAssertEqual(plan.disks, [])
    }

    func testMultipleDisksPutTheBootDiskFirst() throws {
        try requireQemuImg()
        var vmx = String(decoding: try fixture("vmware/debian-12.12-aarch64.vmx"), as: UTF8.self)
        vmx = vmx.replacingOccurrences(of: "sata0:0.filename = \"disk.vmdk\"", with: "sata0:0.filename = \"data.vmdk\"")
        vmx += "sata0:2.filename = \"disk.vmdk\"\nsata0:2.present = \"TRUE\"\n"
        let boot = Self.bootDisk(.gpt), data = Self.bootDisk(.blank)
        let src = try vmwareFolder(boot, vmx: Data(vmx.utf8))
        try image(data, format: "vmdk", at: src.appendingPathComponent("data.vmdk"))
        let plan = try WholeVMImporter.inspect(src)
        XCTAssertEqual(plan.blockers, [], plan.summary)
        XCTAssertEqual(plan.disks.map(\.label), ["sata0:2", "sata0:0"])
        let b = try WholeVMImporter.execute(plan)
        XCTAssertEqual(try b.loadConfig().disks.map(\.path), ["disk.img", "disk2.img"])
        XCTAssertEqual(try Data(contentsOf: b.resolve("disk.img")), boot)
        XCTAssertEqual(try Data(contentsOf: b.resolve("disk2.img")), data)
    }

    // MARK: Parallels

    private func parallelsBundle(descriptor: String? = nil, config: String? = nil) throws -> URL {
        let pvm = try dir("deb.pvm")
        let hdd = pvm.appendingPathComponent("harddisk1.hdd")
        try fm.createDirectory(at: hdd, withIntermediateDirectories: true)
        try Data((config ?? String(decoding: try fixture("parallels/config.pvs"), as: UTF8.self)).utf8).write(to: pvm.appendingPathComponent("config.pvs"))
        try Data((descriptor ?? String(decoding: try fixture("parallels/DiskDescriptor.xml"), as: UTF8.self)).utf8)
            .write(to: hdd.appendingPathComponent("DiskDescriptor.xml"))
        try Data().write(to: hdd.appendingPathComponent("harddisk1.hdd")) // the 0-byte file Parallels keeps (probes as raw)
        try image(Self.bootDisk(.gpt), format: "parallels", at: hdd.appendingPathComponent("harddisk1.hdd.0.{5fbaabe3-6958-40ff-92a7-860e329aab41}.hds"))
        return pvm
    }

    func testParallelsVMImportsWithTheDeclaredFormat() throws {
        try requireQemuImg()
        let pvm = try parallelsBundle()
        let plan = try WholeVMImporter.inspect(pvm)
        XCTAssertEqual(plan.blockers, [], plan.summary)
        XCTAssertEqual(plan.disks.map(\.format), ["parallels"])
        XCTAssertEqual(plan.disks.first?.file.pathExtension, "hds")
        XCTAssertEqual(plan.macAddress, "00:1c:42:6b:b5:94")
        XCTAssertEqual(plan.backend, .vz)
        let b = try WholeVMImporter.execute(plan, overrides: .init(name: "pd-import", memoryMiB: 2048))
        XCTAssertEqual(b.name, "pd-import")
        XCTAssertEqual(try b.loadConfig().memoryMiB, 2048)
        XCTAssertEqual(try Data(contentsOf: b.resolve("disk.img")), Self.bootDisk(.gpt))
    }

    func testParallelsSnapshotsEncryptionAndEscapesAreRefused() throws {
        try requireQemuImg()
        let desc = String(decoding: try fixture("parallels/DiskDescriptor.xml"), as: UTF8.self)
        let twoShots = desc.replacingOccurrences(of: "    </Snapshots>", with: """
                <Shot>
                    <GUID>{11111111-6958-40ff-92a7-860e329aab41}</GUID>
                    <ParentGUID>{5fbaabe3-6958-40ff-92a7-860e329aab41}</ParentGUID>
                </Shot>
            </Snapshots>
        """)
        var pvm = try parallelsBundle(descriptor: twoShots)
        XCTAssertTrue(try WholeVMImporter.inspect(pvm).blockers.contains { $0.code == .snapshots })
        try fm.removeItem(at: pvm)

        let encrypted = desc.replacingOccurrences(of: "<Engine>{00000000-0000-0000-0000-000000000000}</Engine>",
                                                  with: "<Engine>{4b4f4e44-0000-0000-0000-000000000001}</Engine>")
        pvm = try parallelsBundle(descriptor: encrypted)
        XCTAssertTrue(try WholeVMImporter.inspect(pvm).blockers.contains { $0.code == .encrypted })
        try fm.removeItem(at: pvm)

        let escape = desc.replacingOccurrences(of: "<File>harddisk1.hdd.0.{5fbaabe3-6958-40ff-92a7-860e329aab41}.hds</File>",
                                               with: "<File>../../../../etc/hosts</File>")
        pvm = try parallelsBundle(descriptor: escape)
        XCTAssertTrue(try WholeVMImporter.inspect(pvm).blockers.contains { $0.code == .pathOutsideSource })
        try fm.removeItem(at: pvm)

        let config = String(decoding: try fixture("parallels/config.pvs"), as: UTF8.self)
        let vmEncrypted = config.replacingOccurrences(of: "<VmEncryptionInfo dyn_lists=\"\">\n         <Enabled>0</Enabled>",
                                                      with: "<VmEncryptionInfo dyn_lists=\"\">\n         <Enabled>1</Enabled>")
        XCTAssertNotEqual(vmEncrypted, config)
        pvm = try parallelsBundle(config: vmEncrypted)
        XCTAssertTrue(try WholeVMImporter.inspect(pvm).blockers.contains { $0.code == .encrypted })
        try Data().write(to: pvm.appendingPathComponent("{073d97b6}.sav"))
        XCTAssertTrue(try WholeVMImporter.inspect(pvm).blockers.contains { $0.code == .savedState })
    }

    // MARK: VirtualBox

    func testVirtualBoxFixtures() throws {
        func inspect(_ name: String) throws -> ImportPlan {
            let d = try dir(name)
            try fixture("vbox/\(name).vbox").write(to: d.appendingPathComponent("\(name).vbox"))
            return try WholeVMImporter.inspect(d)
        }
        let s1 = try inspect("s1") // saved state, snapshots, differencing disks
        XCTAssertTrue(s1.blockers.contains { $0.code == .savedState }, s1.summary)
        XCTAssertTrue(s1.blockers.contains { $0.code == .snapshots })
        XCTAssertEqual(s1.guestOS, .windows)
        let s5 = try inspect("s5") // a raw physical drive
        XCTAssertTrue(s5.blockers.contains { $0.code == .physicalDisk }, s5.summary)
        let s8 = try inspect("s8") // Arm, saved state
        XCTAssertEqual(s8.architecture, .aarch64)
        XCTAssertEqual(s8.backend, .vz)
        XCTAssertEqual(s8.configuredFirmware, "EFI")
        XCTAssertEqual(s8.macAddress, "08:00:27:11:71:47")
        XCTAssertTrue(s8.blockers.contains { $0.code == .savedState })
        let s9 = try inspect("s9")
        XCTAssertEqual(s9.name, "New-Windows")
        XCTAssertEqual(s9.architecture, .x86_64)
        XCTAssertTrue(s9.blockers.contains { $0.code == .noDisks })
    }

    func testVirtualBoxDiskPathsMustStayInTheFolder() throws {
        let d = try dir("vb")
        let vbox = { (location: String) in Data("""
        <?xml version="1.0"?>
        <VirtualBox xmlns="http://www.virtualbox.org/" version="1.20-macosx">
          <Machine uuid="{a}" name="vb" OSType="Debian12_arm64">
            <MediaRegistry><HardDisks>
              <HardDisk uuid="{d1}" location="\(location)" format="VDI" type="Normal"/>
            </HardDisks></MediaRegistry>
            <Hardware><Memory RAMSize="2048"/><Firmware type="EFI"/>
              <StorageControllers><StorageController name="VirtioSCSI" type="VirtioSCSI">
                <AttachedDevice type="HardDisk" port="0" device="0"><Image uuid="{d1}"/></AttachedDevice>
              </StorageController></StorageControllers>
            </Hardware>
            <Platform architecture="ARM"><CPU count="2"/></Platform>
          </Machine>
        </VirtualBox>
        """.utf8) }
        for bad in ["..\\..\\etc\\x.vdi", "C:/Users/x/x.vdi", "/etc/x.vdi", "../x.vdi"] {
            try vbox(bad).write(to: d.appendingPathComponent("vb.vbox"))
            XCTAssertTrue(try WholeVMImporter.inspect(d).blockers.contains { $0.code == .pathOutsideSource }, bad)
        }
        try requireQemuImg()
        try image(Self.bootDisk(.gpt), format: "vdi", at: d.appendingPathComponent("vb.vdi"))
        try vbox("vb.vdi").write(to: d.appendingPathComponent("vb.vbox"))
        let plan = try WholeVMImporter.inspect(d)
        XCTAssertEqual(plan.blockers, [], plan.summary)
        XCTAssertEqual(plan.disks.map(\.format), ["vdi"])
        XCTAssertEqual(plan.cpuCount, min(2, ProcessInfo.processInfo.processorCount))
    }

    // MARK: OVF / OVA

    func testOVFFolderFromVirtualBox() throws {
        try requireQemuImg()
        let d = try dir("box")
        try fixture("ovf/box.ovf").write(to: d.appendingPathComponent("box.ovf"))
        try image(Self.bootDisk(.gpt), format: "vmdk", at: d.appendingPathComponent("debian-12.12-aarch64-disk001.vmdk"),
                  options: ["-o", "subformat=streamOptimized"])
        let plan = try WholeVMImporter.inspect(d.appendingPathComponent("box.ovf"))
        XCTAssertEqual(plan.blockers, [], plan.summary)
        XCTAssertEqual(plan.architecture, .aarch64)
        XCTAssertEqual(plan.macAddress, "08:00:27:bc:d2:7e")
        XCTAssertEqual(plan.configuredFirmware, "EFI")
    }

    private func photonOVA(manifest: (String, String) -> String? = { "SHA256(\($0))= \($1)" }, extra: [(String, Data, UInt8)] = []) throws -> (URL, Data) {
        let ovf = try fixture("ovf/photon.ovf")
        let raw = Self.bootDisk(.gpt)
        let vmdk = root.appendingPathComponent("photon-disk1-\(UUID()).vmdk")
        try image(raw, format: "vmdk", at: vmdk, options: ["-o", "subformat=streamOptimized"])
        let disk = try Data(contentsOf: vmdk)
        var mf = ""
        if let l = manifest("photon.ovf", Self.sha256(ovf)) { mf += l + "\n" }
        if let l = manifest("photon-disk1.vmdk", Self.sha256(disk)) { mf += l + "\n" }
        let ova = root.appendingPathComponent("photon-\(UUID()).ova")
        try Self.tar([("photon.ovf", ovf, UInt8(ascii: "0")), ("photon.mf", Data(mf.utf8), UInt8(ascii: "0")),
                      ("photon-disk1.vmdk", disk, UInt8(ascii: "0"))] + extra).write(to: ova)
        return (ova, raw)
    }

    func testOVAImportsAfterCheckingItsManifest() throws {
        try requireQemuImg()
        let (ova, raw) = try photonOVA()
        XCTAssertEqual(WholeVMImporter.detect(ova), .ova)
        let plan = try WholeVMImporter.inspect(ova)
        XCTAssertEqual(plan.blockers, [], plan.summary)
        XCTAssertEqual(plan.name, "Photon-OS")
        XCTAssertEqual(plan.sourceName, "Photon OS")
        XCTAssertEqual(plan.architecture, .aarch64, "from the ESP's loader: the OVF doesn't say")
        XCTAssertEqual(plan.disks.first?.member?.digest?.algorithm, .sha256)
        let b = try WholeVMImporter.execute(plan)
        XCTAssertEqual(try Data(contentsOf: b.resolve("disk.img")), raw)
        XCTAssertFalse(fm.fileExists(atPath: b.resolve(".import").path), "the extracted member is removed")
    }

    func testOVAWithABadDigestIsRefused() throws {
        try requireQemuImg()
        let (ova, _) = try photonOVA { name, hex in
            name.hasSuffix(".vmdk") ? "SHA256(\(name))= \(String(repeating: "0", count: 64))" : "SHA256(\(name))= \(hex)"
        }
        let plan = try WholeVMImporter.inspect(ova)
        XCTAssertTrue(plan.blockers.contains { $0.code == .manifest }, plan.summary)
        // A disk the manifest leaves out is refused too.
        let (ova2, _) = try photonOVA { name, hex in name.hasSuffix(".vmdk") ? nil : "SHA1(\(name))= \(String(repeating: "0", count: 40))" }
        let plan2 = try WholeVMImporter.inspect(ova2)
        XCTAssertEqual(plan2.blockers.filter { $0.code == .manifest }.count, 2, plan2.summary)
    }

    func testOVAWithUnsafeMembersIsRefused() throws {
        try requireQemuImg()
        for extra: (String, Data, UInt8) in [("../evil", Data("x".utf8), UInt8(ascii: "0")), ("link", Data(), UInt8(ascii: "2"))] {
            let (ova, _) = try photonOVA(extra: [extra])
            let plan = try WholeVMImporter.inspect(ova)
            XCTAssertTrue(plan.blockers.contains { $0.code == .archive }, plan.summary)
        }
    }

    func testOVFRefusesMultipleVMsAndEmptyDisks() throws {
        let d = try dir("multi")
        try Data("""
        <Envelope xmlns="http://schemas.dmtf.org/ovf/envelope/1" xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1">
          <References/><VirtualSystemCollection>
          <VirtualSystem ovf:id="a"><VirtualHardwareSection/></VirtualSystem>
          <VirtualSystem ovf:id="b"><VirtualHardwareSection/></VirtualSystem></VirtualSystemCollection>
        </Envelope>
        """.utf8).write(to: d.appendingPathComponent("m.ovf"))
        XCTAssertTrue(try WholeVMImporter.inspect(d).blockers.contains { $0.code == .multipleVMs })
    }

    func testUbuntuOVFFixture() throws {
        // The x86 cloud image: BIOS in its config, 1 GiB of memory.
        try requireQemuImg()
        let d = try dir("ubuntu")
        try fixture("ovf/ubuntu.ovf").write(to: d.appendingPathComponent("ubuntu.ovf"))
        try image(Self.bootDisk(.gpt, loader: "BOOTX64 EFI", vendor: "UBUNTU"), format: "vmdk",
                  at: d.appendingPathComponent("ubuntu-noble-24.04-cloudimg.vmdk"), options: ["-o", "subformat=streamOptimized"])
        let plan = try WholeVMImporter.inspect(d)
        XCTAssertEqual(plan.blockers, [], plan.summary)
        XCTAssertEqual(plan.architecture, .x86_64)
        XCTAssertEqual(plan.backend, .qemu)
        XCTAssertEqual(plan.memoryMiB, 2048)
        XCTAssertTrue(plan.warnings.contains { $0.code == .memoryRaised })
        XCTAssertTrue(plan.warnings.contains { $0.code == .firmwareConfig })
        XCTAssertTrue(plan.warnings.contains { $0.code == .emulated })
        let b = try WholeVMImporter.execute(plan)
        XCTAssertEqual(try b.loadConfig().disks.first?.interface, .nvme)
    }

    // MARK: Execute

    func testCancelledImportLeavesNothingBehind() throws {
        try requireQemuImg()
        let plan = try WholeVMImporter.inspect(vmwareFolder(Self.bootDisk(.gpt)))
        let cancel = DiskImport.Cancellation()
        cancel.cancel()
        XCTAssertThrowsError(try WholeVMImporter.execute(plan, cancellation: cancel)) { XCTAssertEqual($0 as? VitrineError, .cancelled) }
        XCTAssertFalse(fm.fileExists(atPath: VMLibrary.bundleURL(named: plan.name).path))
    }

    func testExecuteRefusesAnInvalidNameAndAnExistingVM() throws {
        try requireQemuImg()
        let plan = try WholeVMImporter.inspect(vmwareFolder(Self.bootDisk(.gpt)))
        XCTAssertThrowsError(try WholeVMImporter.execute(plan, overrides: .init(name: "../../out")))
        XCTAssertThrowsError(try WholeVMImporter.execute(plan, overrides: .init(cpuCount: 10_000)))
        XCTAssertFalse(fm.fileExists(atPath: VMLibrary.bundleURL(named: plan.name).path))
        XCTAssertTrue(try WholeVMImporter.inspect(root.appendingPathComponent("deb.vmwarevm"), name: "a/b").blockers.contains { $0.code == .invalidName })
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("out.vitrinevm").path))
        try WholeVMImporter.execute(plan)
        XCTAssertTrue(try WholeVMImporter.inspect(root.appendingPathComponent("deb.vmwarevm")).warnings.contains { $0.code == .nameTaken })
        XCTAssertThrowsError(try WholeVMImporter.execute(plan))
    }
}
