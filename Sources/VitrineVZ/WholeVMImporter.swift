import Foundation
import VitrineCore
import VitrineQEMU

/// Imports whole VMs from other tools: OVA/OVF packages, VMware (.vmwarevm / .vmx), Parallels
/// Desktop (.pvm) and VirtualBox (.vbox) machines. `inspect` works out an `ImportPlan` without
/// writing anything (it reads the configuration, runs `qemu-img info` and reads the boot disk's
/// partition table and EFI system partition); `execute` turns a plan without blockers into a
/// Vitrine VM, converting every disk to raw. The source is never changed.
///
/// Vitrine boots VMs with UEFI only, so a guest that can only boot with BIOS is refused, as are
/// VMs whose state can't be carried over faithfully: suspended, encrypted, with snapshots, with
/// disks outside their own folder or in unreadable formats.
public enum WholeVMImporter {
    /// The format of `url`, if it is one this importer reads (nil: a bare disk image, a UTM bundle,
    /// or something else).
    public static func detect(_ url: URL) -> ImportPlan.SourceFormat? {
        (try? locate(url))?.format
    }

    /// `detect`, but saying why a folder that looks like a VM can't be read (two .vmx files, a
    /// .vmwarevm without one).
    public static func detectFormat(_ url: URL) throws -> ImportPlan.SourceFormat? {
        try locate(url)?.format
    }

    /// Where a source's configuration and folder are.
    struct Location { var format: ImportPlan.SourceFormat; var config: URL; var root: URL }

    static func locate(_ input: URL) throws -> Location? {
        let url = input.standardizedFileURL
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { throw VitrineError.fileNotFound(url.path) }
        let ext = url.pathExtension.lowercased()
        func one(_ e: String, in dir: URL) throws -> URL? {
            let found = files(in: dir).filter { $0.pathExtension.lowercased() == e && !$0.lastPathComponent.hasPrefix("._") }
            guard found.count <= 1 else {
                throw VitrineError.invalidConfig("\(dir.lastPathComponent) holds \(found.count) .\(e) files; point at the one to import")
            }
            return found.first
        }
        if !isDir.boolValue {
            let dir = url.deletingLastPathComponent()
            switch ext {
            case "ova": return Location(format: .ova, config: url, root: dir)
            case "ovf": return Location(format: .ovf, config: url, root: dir)
            case "vmx": return Location(format: .vmware, config: url, root: dir)
            case "vbox": return Location(format: .virtualBox, config: url, root: dir)
            case "pvs" where url.lastPathComponent == "config.pvs": return Location(format: .parallels, config: url, root: dir)
            default: return nil
            }
        }
        switch ext {
        case "pvm": return Location(format: .parallels, config: url.appendingPathComponent("config.pvs"), root: url)
        case "utm", "vitrinevm": return nil
        default: break
        }
        if let vmx = try one("vmx", in: url) { return Location(format: .vmware, config: vmx, root: url) }
        if ext == "vmwarevm" { throw VitrineError.invalidConfig("\(url.lastPathComponent) has no .vmx file") }
        if let vbox = try one("vbox", in: url) { return Location(format: .virtualBox, config: vbox, root: url) }
        if let ovf = try one("ovf", in: url) { return Location(format: .ovf, config: ovf, root: url) }
        if fm.fileExists(atPath: url.appendingPathComponent("config.pvs").path) {
            return Location(format: .parallels, config: url.appendingPathComponent("config.pvs"), root: url)
        }
        return nil
    }

    // MARK: Inspect

    /// The plan for importing `url`. Throws only when `url` isn't a VM this importer reads, or its
    /// configuration can't be parsed at all; everything else that stands in the way is a blocker.
    /// `name` replaces the source's name (it must be a valid VM name). Writes nothing (a temporary
    /// file may hold a few MB read from a non-raw boot disk).
    public static func inspect(_ url: URL, name: String? = nil, cancellation: DiskImport.Cancellation? = nil) throws -> ImportPlan {
        guard let loc = try locate(url) else {
            throw VitrineError.unsupported("\(url.lastPathComponent) isn't an OVA/OVF package or a VMware, Parallels or VirtualBox VM")
        }
        let root = loc.root.resolvingSymlinksInPath().standardizedFileURL
        guard let config = ImportPath.contained(loc.config, in: root) else {
            throw VitrineError.invalidConfig("\(loc.config.lastPathComponent) resolves outside its folder")
        }
        var facts: Facts
        switch loc.format {
        case .vmware: facts = try vmware(config, root: root)
        case .parallels: facts = try parallels(root)
        case .virtualBox: facts = try virtualBox(config, root: root)
        case .ovf: facts = try ovfFolder(config, root: root, cancellation: cancellation)
        case .ova: facts = try ova(config, cancellation: cancellation)
        }
        facts.source = url.standardizedFileURL
        return try finalize(facts, explicitName: name, cancellation: cancellation)
    }

    static func ovfFolder(_ ovfURL: URL, root: URL, cancellation: DiskImport.Cancellation?) throws -> Facts {
        var f = Facts(.ovf, source: ovfURL, root: root, app: "the exporting tool")
        let data = try readConfig(ovfURL)
        let dir = ovfURL.deletingLastPathComponent()
        try ovf(data, into: &f) { href in
            ImportPath.resolve(href, base: dir, root: root).map { ($0, nil) }
        }
        let mfURL = ovfURL.deletingPathExtension().appendingPathExtension("mf")
        if FileManager.default.fileExists(atPath: mfURL.path) {
            do {
                let manifest = try OVFManifest.parse(readConfig(mfURL, limit: 1 << 20))
                f.manifest = manifest
                verify(ovfURL.lastPathComponent, data: data, manifest: manifest, into: &f)
                for d in f.disks {
                    guard let file = d.file else { continue }
                    try cancellation?.check()
                    verifyFile(d.reference, url: file, offset: 0, size: nil, manifest: manifest, into: &f, cancellation: cancellation)
                }
            } catch let e as VitrineError where e == .cancelled {
                throw e
            } catch {
                f.block(.manifest, "the package's manifest (\(mfURL.lastPathComponent)) is unreadable: \(error.localizedDescription)")
            }
        }
        if FileManager.default.fileExists(atPath: ovfURL.deletingPathExtension().appendingPathExtension("cert").path) {
            f.warn(.signatureNotChecked, "the package is signed (.cert); Vitrine checks its manifest digests but not the signature")
        }
        return f
    }

    static func ova(_ archive: URL, cancellation: DiskImport.Cancellation?) throws -> Facts {
        var f = Facts(.ova, source: archive, root: archive.deletingLastPathComponent(), app: "the exporting tool")
        f.archive = archive
        let members: [TarListing.Member]
        do { members = try TarListing.list(archive) } catch {
            f.block(.archive, error.localizedDescription)
            return f
        }
        let ovfs = members.filter { $0.name.lowercased().hasSuffix(".ovf") }
        guard ovfs.count == 1, let ovfMember = ovfs.first else {
            f.block(.archive, "the OVA holds \(ovfs.count) OVF descriptors; expected exactly one")
            return f
        }
        guard ovfMember.size <= UInt64(ImportXML.maximumSize) else { throw VitrineError.invalidConfig("the OVF descriptor is too large") }
        let data = try readMember(archive, ovfMember)
        var byName: [String: TarListing.Member] = [:]
        for m in members { byName[m.name] = m }
        try ovf(data, into: &f) { href in
            guard TarListing.isPlainName(href), let m = byName[href] else { return nil }
            return (archive, ImportPlan.ArchiveMember(name: m.name, offset: m.offset, size: m.size))
        }
        if let mf = members.first(where: { $0.name.lowercased().hasSuffix(".mf") }) {
            do {
                let manifest = try OVFManifest.parse(readMember(archive, mf, limit: 1 << 20))
                f.manifest = manifest
                verify(ovfMember.name, data: data, manifest: manifest, into: &f)
                for i in f.disks.indices {
                    guard let m = f.disks[i].member else { continue }
                    f.disks[i].member?.digest = manifest[m.name]
                    try cancellation?.check()
                    verifyFile(m.name, url: archive, offset: m.offset, size: m.size, manifest: manifest, into: &f, cancellation: cancellation)
                }
            } catch let e as VitrineError where e == .cancelled {
                throw e
            } catch {
                f.block(.manifest, "the OVA's manifest (\(mf.name)) is unreadable: \(error.localizedDescription)")
            }
        }
        if members.contains(where: { $0.name.lowercased().hasSuffix(".cert") }) {
            f.warn(.signatureNotChecked, "the package is signed (.cert); Vitrine checks its manifest digests but not the signature")
        }
        return f
    }

    static func readMember(_ archive: URL, _ m: TarListing.Member, limit: Int = ImportXML.maximumSize) throws -> Data {
        guard m.size <= UInt64(limit) else { throw VitrineError.invalidConfig("\(m.name) is too large") }
        let h = try FileHandle(forReadingFrom: archive)
        defer { try? h.close() }
        try h.seek(toOffset: m.offset)
        let d = try h.read(upToCount: Int(m.size)) ?? Data()
        guard d.count == Int(m.size) else { throw VitrineError.io("\(m.name) is truncated") }
        return d
    }

    static func verify(_ name: String, data: Data, manifest: [String: ImportPlan.Digest], into f: inout Facts) {
        guard let want = manifest[name] else {
            f.block(.manifest, "the manifest has no digest for \(name)")
            return
        }
        var h = ImportHasher(want.algorithm)
        h.update(data)
        if h.finalize() != want.hex { f.block(.manifest, "\(name) doesn't match the manifest's \(want.algorithm.rawValue.uppercased()) digest; the package is damaged or was altered") }
    }

    static func verifyFile(_ name: String, url: URL, offset: UInt64, size: UInt64?, manifest: [String: ImportPlan.Digest],
                           into f: inout Facts, cancellation: DiskImport.Cancellation?) {
        guard let want = manifest[name] else {
            f.block(.manifest, "the manifest has no digest for \(name)")
            return
        }
        do {
            let got = try ImportHasher.digest(of: url, offset: offset, length: size, algorithm: want.algorithm) { cancellation?.isCancelled == true }
            if got != want.hex { f.block(.manifest, "\(name) doesn't match the manifest's \(want.algorithm.rawValue.uppercased()) digest; the package is damaged or was altered") }
        } catch {
            f.block(.manifest, "couldn't check \(name) against the manifest: \(error.localizedDescription)")
        }
    }

    // MARK: Disks and boot

    /// Problems with a disk's image file found before `qemu-img` opens it: a VMDK descriptor's
    /// extents and parent link (a descriptor can name any file on the Mac), and for OVA members,
    /// that the image is a single self-describing file.
    static func precheck(_ d: DiskRef, root: URL, app: String) -> [ImportPlan.Issue] {
        guard let file = d.file, let format = d.format else { return [] }
        let head: Data
        do {
            let h = try FileHandle(forReadingFrom: file)
            defer { try? h.close() }
            try h.seek(toOffset: d.member?.offset ?? 0)
            head = try h.read(upToCount: Int(min(d.member?.size ?? UInt64(1 << 20), UInt64(1 << 20)))) ?? Data()
        } catch {
            return [.init(.diskMissing, "the disk \(d.reference) can't be read: \(error.localizedDescription)")]
        }
        // A VMDK's descriptor: the file itself (text), or embedded in a sparse header whose capacity
        // is 0, which makes qemu follow the embedded descriptor's extents too.
        var desc: VMDKDescriptor?
        if format == "vmdk" {
            if head.prefix(4) == Data("KDMV".utf8) {
                if le64(head, 12) == 0 {
                    let off = le64(head, 28), size = le64(head, 36)
                    guard d.member == nil, off > 0, size > 0, size <= 2048,
                          let embedded = try? readRange(file, at: off * 512, length: Int(size * 512)),
                          let parsed = VMDKDescriptor(data: Data(embedded.prefix { $0 != 0 })) else {
                        return [.init(.diskFormat, "the disk \(d.reference) is a VMDK whose embedded descriptor names other files; only self-contained disks are imported")]
                    }
                    desc = parsed
                }
            } else {
                desc = VMDKDescriptor(data: head)
            }
        }
        if d.member != nil {
            let magic: [String: Data] = ["vmdk": Data("KDMV".utf8), "qcow2": Data([0x51, 0x46, 0x49, 0xFB])]
            if let m = magic[format], head.prefix(4) != m {
                return [.init(.diskFormat, "the disk \(d.reference) inside the OVA isn't a self-contained \(format) image (a descriptor naming other files, say); only single-file disks are imported from an OVA")]
            }
            return []
        }
        guard let desc else { return [] }
        var issues: [ImportPlan.Issue] = []
        if desc.hasParent {
            issues.append(.init(.snapshots, "the disk \(d.reference) is a snapshot (it has a parent disk); delete the VM's snapshots in \(app) first so its disks are merged"))
        }
        let dir = file.deletingLastPathComponent()
        for e in desc.extents {
            if ["VMFSRDM", "VMFSRAW", "VMFSPASSTHROUGH"].contains(e.type) {
                issues.append(.init(.physicalDisk, "the disk \(d.reference) maps a physical device (\(e.type)); only disk images can be imported"))
            } else if e.type == "ZERO" {
                continue
            } else if let name = e.file {
                if ImportPath.resolve(name, base: dir, root: root) == nil {
                    issues.append(.init(.pathOutsideSource, "the disk \(d.reference) reads from \(name.debugDescription), outside the VM's folder; only disks inside it are imported"))
                }
            } else {
                issues.append(.init(.diskFormat, "the disk \(d.reference) has an extent without a file"))
            }
        }
        if desc.extents.isEmpty { issues.append(.init(.diskFormat, "the disk descriptor \(d.reference) lists no extents")) }
        return issues
    }

    static func le64(_ d: Data, _ o: Int) -> UInt64 {
        guard d.count >= o + 8 else { return 0 }
        return (0..<8).reduce(UInt64(0)) { $0 | UInt64(d[d.startIndex + o + $1]) << (8 * UInt64($1)) }
    }

    static func readRange(_ file: URL, at offset: UInt64, length: Int) throws -> Data {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        try h.seek(toOffset: offset)
        return try h.read(upToCount: length) ?? Data()
    }

    /// Guest-visible reads from a disk for `BootDiskProbe`: directly for raw files, else through
    /// `qemu-img` in 1 MiB chunks (at most 48 of them: the probe needs a few).
    final class DiskReader {
        let size: UInt64
        private let fetch: (UInt64, Int) throws -> Data
        private var cache: [UInt64: Data] = [:]
        private var budget = 48
        static let chunk = 1 << 20

        init(size: UInt64, fetch: @escaping (UInt64, Int) throws -> Data) { self.size = size; self.fetch = fetch }

        func read(_ offset: UInt64, _ length: Int) throws -> Data {
            guard offset < size, length > 0 else { return Data() }
            var out = Data()
            var pos = offset
            let end = min(offset + UInt64(length), size)
            while pos < end {
                let base = pos / UInt64(Self.chunk) * UInt64(Self.chunk)
                let data: Data
                if let c = cache[base] { data = c } else {
                    guard budget > 0 else { throw VitrineError.io("read limit reached") }
                    budget -= 1
                    data = try fetch(base, Self.chunk)
                    cache[base] = data
                }
                let from = Int(pos - base), to = min(data.count, Int(end - base))
                guard from < to else { break }
                out += data.subdata(in: from..<to)
                pos = base + UInt64(to)
            }
            return out
        }
    }

    static func probe(_ d: ImportPlan.Disk, cancellation: DiskImport.Cancellation?) throws -> BootDiskProbe.Result {
        let size = d.virtualSize ?? 0
        let reader: DiskReader
        if d.format == "raw", d.member == nil {
            let h = try FileHandle(forReadingFrom: d.file)
            reader = DiskReader(size: size) { off, len in
                try h.seek(toOffset: off)
                return try h.read(upToCount: len) ?? Data()
            }
            defer { try? h.close() }
            return try BootDiskProbe.probe(diskSize: size, read: reader.read)
        }
        let spec = DiskImport.blockSpec(file: d.file, format: d.format, window: d.member.map { ($0.offset, $0.size) })
        reader = DiskReader(size: size) { off, len in
            try DiskImport.read(spec: spec, virtualSize: size, offset: off, length: len, cancellation: cancellation)
        }
        return try BootDiskProbe.probe(diskSize: size, read: reader.read)
    }

    static func finalize(_ f: Facts, explicitName: String?, cancellation: DiskImport.Cancellation?) throws -> ImportPlan {
        let hostCPUs = ProcessInfo.processInfo.processorCount
        let hostMiB = ProcessInfo.processInfo.physicalMemory / (1 << 20)
        let derived = f.name ?? f.source.deletingPathExtension().lastPathComponent
        var plan = ImportPlan(format: f.format, source: f.source, sourceRoot: f.root,
                              name: VMImportName.sanitize(derived), cpuCount: 2, memoryMiB: 4096)
        plan.sourceName = f.name
        f.blockers.forEach { plan.block($0.code, $0.message) }
        f.warnings.forEach { plan.warn($0.code, $0.message) }
        plan.configuredFirmware = f.firmware

        // Name
        if let explicitName {
            if VMCreationJob.isValidVMName(explicitName) { plan.name = explicitName }
            else { plan.block(.invalidName, "\(explicitName.debugDescription) is not a valid VM name (letters, digits, '.', '-' and '_', up to 64, starting with a letter or digit)") }
        } else if plan.name != derived {
            plan.warn(.nameChanged, "named the VM \(plan.name) (VM names use letters, digits, '.', '-' and '_')")
        }
        if FileManager.default.fileExists(atPath: VMLibrary.bundleURL(named: plan.name).path) {
            plan.warn(.nameTaken, "a VM named \(plan.name) already exists; import under another name")
        }
        if f.guestOS == .macOS {
            plan.block(.macOSGuest, "macOS VMs from \(f.app) can't be imported: a macOS guest is tied to its platform identity, which doesn't carry over; create a new macOS VM instead")
        }

        // Disks: check before anything reads them, then describe them with qemu-img.
        if f.disks.isEmpty && f.blockers.isEmpty { plan.block(.noDisks, "the VM has no disk to import") }
        let needsQemu = f.disks.contains { $0.format != "raw" || $0.member != nil }
        let haveQemu = DiskImport.isQemuImgAvailable
        if needsQemu && !haveQemu {
            plan.block(.qemuMissing, "reading this VM's disks needs qemu-img; install QEMU (brew install qemu) and try again")
        }
        var usable: [ImportPlan.Disk] = []
        for ref in f.disks {
            guard let file = ref.file, let format = ref.format else { continue }
            guard FileManager.default.fileExists(atPath: file.path) else {
                plan.block(.diskMissing, "the disk \(ref.reference) (\(ref.label)) is missing")
                continue
            }
            let issues = precheck(ref, root: f.root, app: f.app)
            issues.forEach { plan.block($0.code, $0.message) }
            guard issues.isEmpty, !needsQemu || haveQemu else { continue }
            var disk = ImportPlan.Disk(file: file, member: ref.member, format: format, label: ref.label, readOnly: ref.readOnly)
            if format == "raw" && ref.member == nil {
                disk.virtualSize = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.uint64Value
            } else {
                do {
                    try cancellation?.check()
                    let info: DiskImport.Info
                    if let m = ref.member {
                        info = try DiskImport.info(spec: DiskImport.blockSpec(file: file, format: format, window: (m.offset, m.size)))
                        if let b = info.backingFiles.first { throw VitrineError.unsupported("it reads from another file (\(b))") }
                        // The only file an OVA member's image may read is itself (the json: node).
                        if let other = info.extents.first(where: { !$0.hasPrefix("json:") }) ?? (info.extents.count > 1 ? info.extents[1] : nil) {
                            throw VitrineError.unsupported("it reads from another file (\(other))")
                        }
                    } else {
                        info = try DiskImport.info(file, format: format)
                        try DiskImport.checkSelfContained(file, info, root: f.root)
                    }
                    disk.virtualSize = info.virtualSize
                } catch let e as VitrineError where e == .cancelled {
                    throw e
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    let snapshot = message.contains("reads from another file")
                    plan.block(snapshot ? .snapshots : .diskFormat,
                               "the disk \(ref.reference) can't be imported as \(format): \(message)"
                               + (snapshot ? " (delete the VM's snapshots in \(f.app) first)" : ""))
                    continue
                }
            }
            usable.append(disk)
        }

        // Boot disk: the first one with an EFI system partition.
        var probes: [BootDiskProbe.Result?] = []
        for d in usable {
            try cancellation?.check()
            do { probes.append(try probe(d, cancellation: cancellation)) } catch let e as VitrineError where e == .cancelled {
                throw e
            } catch {
                probes.append(nil)
                plan.warn(.other, "couldn't read the partition table of \(d.label): \(error.localizedDescription)")
            }
        }
        if let i = probes.firstIndex(where: { $0?.hasESP == true }) {
            let boot = usable.remove(at: i)
            usable.insert(boot, at: 0)
            plan.bootDisk = probes[i]
        } else if let first = probes.first {
            plan.bootDisk = first
        }
        plan.disks = usable
        let probe = plan.bootDisk
        let appName = f.app
        if let p = probe {
            if p.hasESP {
                plan.firmware = .uefi
                if let c = f.firmware?.lowercased(), c.hasPrefix("bios") {
                    plan.warn(.firmwareConfig, "\(appName) boots this VM with BIOS, but its disk also has a UEFI boot loader; Vitrine boots it with UEFI")
                }
                if let e = p.espError { plan.warn(.noFallbackLoader, "couldn't read the EFI system partition (\(e)); the VM may not find its boot loader") }
            } else {
                plan.firmware = p.scheme == .none ? .unknown : .bios
                let what = p.scheme == .none ? "no partition table Vitrine can read" : "no EFI system partition (\(p.scheme.rawValue.uppercased()) disk)"
                plan.block(p.scheme == .none ? .noBootPartition : .biosOnly,
                           "the boot disk has \(what): it boots only with legacy BIOS, and Vitrine starts VMs with UEFI. Convert the guest to UEFI in \(appName) first (or reinstall it)")
            }
        } else if !usable.isEmpty && plan.blockers.isEmpty {
            plan.block(.noBootPartition, "couldn't read the boot disk's partition table, so whether it boots with UEFI is unknown")
        }

        // Guest OS and architecture: the configuration's, checked against the boot loader on disk.
        var os = f.guestOS
        if os == nil {
            if probe?.looksLikeWindows == true { os = .windows }
            else {
                os = .linux
                plan.warn(.guestOSAssumed, "\(appName) doesn't say which OS the VM runs; assumed Linux (change it in the VM's configuration if wrong)")
            }
        }
        plan.guestOS = os ?? .linux
        var arch = f.architecture
        if let diskArch = probe?.architecture {
            if let a = arch, a != diskArch {
                plan.warn(.architectureFromDisk, "\(appName) says the VM is \(a.rawValue), but its boot loader is \(diskArch.rawValue); importing it as \(diskArch.rawValue)")
            }
            arch = diskArch
        }
        if arch == nil, let p = probe, p.hasESP, !p.fallbackLoaders.isEmpty {
            plan.block(.unsupportedArchitecture, "the boot disk only has \(p.fallbackLoaders.joined(separator: ", ")) (32-bit); only arm64 and x86_64 guests are supported")
        }
        if arch == nil && plan.blockers.isEmpty {
            plan.warn(.architectureFromDisk, "couldn't tell the VM's architecture; assumed arm64")
        }
        plan.architecture = arch ?? .aarch64
        if let p = probe, p.hasESP, p.espError == nil {
            let wanted = plan.architecture == .aarch64 ? "BOOTAA64.EFI" : "BOOTX64.EFI"
            if !p.fallbackLoaders.contains(wanted) {
                plan.warn(.noFallbackLoader, "the EFI system partition has no EFI/BOOT/\(wanted). The VM's boot entries live in \(appName)'s NVRAM, which isn't imported, so the firmware may not find the boot loader. Before importing, install the fallback loader in the guest (Debian/Ubuntu: grub-install --removable, or \"force extra removable\" in dpkg-reconfigure grub-efi), or boot it once and fix it from the UEFI shell")
            }
        }
        switch (plan.guestOS, plan.architecture) {
        case (.linux, .aarch64): plan.backend = .vz
        default: plan.backend = .qemu
        }
        if plan.architecture == .x86_64 {
            plan.warn(.emulated, "x86_64 guests are emulated on Apple silicon (QEMU) and run many times slower than native ones")
        }
        if plan.guestOS == .windows {
            plan.warn(.basicDisplay, VMConfig.DisplayConfig.basicFramebufferImportNote)
        }
        if plan.guestOS == .linux {
            plan.warn(.networkDrivers, "the guest gets virtio/NVMe disks and a virtio network adapter: its network interface may get a new name (reconfigure it if the network doesn't come up)")
        }

        // CPUs and memory: what the source asks for, within what this Mac and Vitrine allow.
        if let n = f.cpus, n > 0 {
            plan.cpuCount = min(n, hostCPUs)
            if n > hostCPUs { plan.warn(.cpusReduced, "reduced CPUs from \(n) to \(hostCPUs), the number this Mac has") }
        } else {
            plan.cpuCount = min(max(2, hostCPUs / 2), hostCPUs)
            plan.warn(.cpusMissing, "\(appName) doesn't say how many CPUs the VM has; gave it \(plan.cpuCount)")
        }
        if let mib = f.memoryMiB, mib > 0 {
            var m = mib
            if m < VMConfig.minimumMemoryMiB {
                plan.warn(.memoryRaised, "raised memory from \(m) MiB to \(VMConfig.minimumMemoryMiB) MiB, Vitrine's minimum")
                m = VMConfig.minimumMemoryMiB
            }
            if m > hostMiB {
                plan.warn(.memoryReduced, "reduced memory from \(m) MiB to \(hostMiB) MiB, the amount this Mac has")
                m = hostMiB
            }
            plan.memoryMiB = m
        } else {
            plan.memoryMiB = min(4096, hostMiB)
            plan.warn(.memoryMissing, "\(appName) doesn't say how much memory the VM has; gave it \(plan.memoryMiB) MiB")
        }

        // Network
        plan.networkDisabled = f.networkDisabled
        if let raw = f.mac {
            if let mac = normalizeMAC(raw) { plan.macAddress = mac }
            else { plan.warn(.macReplaced, "the VM's MAC address \(raw.debugDescription) isn't a usable unicast address; it gets a new one") }
        }
        return plan
    }

    /// "001C426BB594", "00-1c-42-6b-b5-94", "00:1C:42:6B:B5:94" → "00:1c:42:6b:b5:94"; nil for
    /// anything else, and for multicast addresses (a NIC can't have one).
    public static func normalizeMAC(_ raw: String) -> String? {
        let hex = raw.trimmingCharacters(in: .whitespaces).filter { $0 != ":" && $0 != "-" && $0 != "." }
        guard hex.count == 12, hex.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }) else { return nil }
        let lower = hex.lowercased()
        let octets = stride(from: 0, to: 12, by: 2).map { i -> String in
            let a = lower.index(lower.startIndex, offsetBy: i)
            return String(lower[a..<lower.index(a, offsetBy: 2)])
        }
        guard let first = UInt8(octets[0], radix: 16), first & 1 == 0, octets.joined() != "000000000000" else { return nil }
        let mac = octets.joined(separator: ":")
        return VMConfig.NetworkConfig.isMACAddress(mac) ? mac : nil
    }

    // MARK: Execute

    public struct Overrides: Sendable {
        public var name: String?
        public var cpuCount: Int?
        public var memoryMiB: UInt64?
        public init(name: String? = nil, cpuCount: Int? = nil, memoryMiB: UInt64? = nil) {
            self.name = name; self.cpuCount = cpuCount; self.memoryMiB = memoryMiB
        }
    }

    /// Creates the VM `plan` describes (which must have no blockers): a bundle, locked and hidden
    /// while its disks are converted to raw (each opened as the format the source declares), and
    /// deleted again if anything fails or `cancellation` fires. OVA members are copied out of the
    /// archive into the new bundle first, checked against the manifest as they are copied.
    @discardableResult
    public static func execute(_ plan: ImportPlan, overrides: Overrides = .init(),
                               cancellation: DiskImport.Cancellation? = nil,
                               progress: (String) -> Void = { _ in }) throws -> VMBundle {
        guard plan.blockers.isEmpty else {
            throw VitrineError.unsupported("the VM can't be imported: " + plan.blockers.map(\.message).joined(separator: "; "))
        }
        let name = try VMImportName.resolve(explicit: overrides.name, derived: plan.name)
        var config = VMConfig(name: name, guestOS: plan.guestOS, cpuCount: overrides.cpuCount ?? plan.cpuCount,
                              memoryMiB: overrides.memoryMiB ?? plan.memoryMiB)
        config.architecture = plan.architecture
        config.backend = plan.backend
        if plan.guestOS == .linux { config.boot = .efi }
        // Windows from another tool has no viogpudo driver: virtio-gpu alone would show nothing.
        if plan.guestOS == .windows { config.display.basicFramebuffer = true }
        if let mac = plan.macAddress { config.network.macAddress = mac }
        if plan.networkDisabled { config.network.mode = .none }
        let interface: VMConfig.DiskConfig.Interface = plan.backend == .qemu ? .nvme : .virtio
        config.disks = plan.disks.indices.map {
            .init(path: $0 == 0 ? "disk.img" : "disk\($0 + 1).img", readOnly: plan.disks[$0].readOnly, interface: interface)
        }
        // The disks must still be where the plan found them (inside the source's folder).
        for d in plan.disks where d.member == nil {
            guard ImportPath.contained(d.file, in: plan.sourceRoot) != nil else {
                throw VitrineError.invalidConfig("\(d.file.path) is no longer inside \(plan.sourceRoot.path)")
            }
            let ref = DiskRef(reference: d.file.lastPathComponent, file: d.file, format: d.format, label: d.label)
            if let issue = precheck(ref, root: plan.sourceRoot, app: plan.format.displayName).first {
                throw VitrineError.unsupported(issue.message)
            }
        }
        // Overrides (CPUs, memory) are checked before any disk is converted.
        try config.validate()
        let url = VMLibrary.bundleURL(named: name)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw VitrineError.invalidConfig("a VM named \(name) already exists") }
        return try VMBundle.create(at: url, config: config) { bundle, config in
            for (i, d) in plan.disks.enumerated() {
                try cancellation?.check()
                let dest = bundle.resolve(config.disks[i].path)
                progress("converting disk \(i + 1) of \(plan.disks.count) (\(d.label), \(d.format)\(d.virtualSize.map { ", " + ImportPlan.formatBytes($0) } ?? ""))")
                if let m = d.member {
                    let dir = bundle.resolve(".import")
                    if !FileManager.default.fileExists(atPath: dir.path) {
                        guard mkdir(dir.path, 0o700) == 0 else { throw VitrineError.io("cannot create \(dir.path)") }
                    }
                    let extracted = try extract(m, from: d.file, into: dir, cancellation: cancellation, progress: progress)
                    let ref = DiskRef(reference: m.name, file: extracted, format: d.format, label: d.label)
                    if let issue = precheck(ref, root: dir, app: plan.format.displayName).first {
                        throw VitrineError.unsupported(issue.message)
                    }
                    let head = try FileHandle(forReadingFrom: extracted)
                    let magic = try head.read(upToCount: 4) ?? Data()
                    try? head.close()
                    if d.format == "vmdk", magic != Data("KDMV".utf8) {
                        throw VitrineError.unsupported("\(m.name) isn't a self-contained VMDK")
                    }
                    try DiskImport.convert(extracted, to: dest, format: d.format, root: dir, cancellation: cancellation)
                    try FileManager.default.removeItem(at: extracted)
                } else {
                    try DiskImport.convert(d.file, to: dest, format: d.format, root: plan.sourceRoot, cancellation: cancellation)
                }
            }
            try? FileManager.default.removeItem(at: bundle.resolve(".import"))
            try cancellation?.check()
            try config.validate(bundle: bundle)
        }
    }

    /// Copies an archive member into `dir` (as its plain name), hashing it on the way and checking
    /// the digest against the manifest's, so the bytes converted are the bytes verified.
    static func extract(_ m: ImportPlan.ArchiveMember, from archive: URL, into dir: URL,
                        cancellation: DiskImport.Cancellation?, progress: (String) -> Void) throws -> URL {
        guard TarListing.isPlainName(m.name) else { throw VitrineError.invalidConfig("bad member name \(m.name.debugDescription)") }
        let dest = dir.appendingPathComponent(m.name)
        let fd = open(dest.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw VitrineError.io("cannot create \(dest.path): \(String(cString: strerror(errno)))") }
        let out = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close(); try? out.close() }
        try input.seek(toOffset: m.offset)
        var hasher = m.digest.map { ImportHasher($0.algorithm) }
        var remaining = m.size
        while remaining > 0 {
            try cancellation?.check()
            let chunk = try input.read(upToCount: Int(min(remaining, 8 << 20))) ?? Data()
            guard !chunk.isEmpty else { throw VitrineError.io("\(m.name) ends early in \(archive.lastPathComponent)") }
            hasher?.update(chunk)
            try out.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
        }
        if let want = m.digest, let got = hasher?.finalize(), got != want.hex {
            throw VitrineError.invalidConfig("\(m.name) doesn't match the manifest's digest; the package changed or is damaged")
        }
        return dest
    }
}
