import Foundation
import VitrineCore

// Reading each tool's VM configuration into `WholeVMImporter.Facts`. Nothing here writes, and every
// file a configuration names goes through `ImportPath.resolve`, which refuses paths that leave the
// VM's folder.

extension WholeVMImporter {
    /// What a source's configuration says, before its disks are looked at.
    struct Facts {
        var format: ImportPlan.SourceFormat
        var source: URL
        var root: URL
        var app: String
        var name: String?
        var guestOS: VMConfig.GuestOS?
        var architecture: VMConfig.Architecture?
        var firmware: String?
        var cpus: Int?
        var memoryMiB: UInt64?
        var mac: String?
        var networkDisabled = false
        var disks: [DiskRef] = []
        var blockers: [ImportPlan.Issue] = []
        var warnings: [ImportPlan.Issue] = []
        /// OVF packages: the manifest's digests by file name, and where to find the files.
        var manifest: [String: ImportPlan.Digest]?
        var archive: URL?

        init(_ format: ImportPlan.SourceFormat, source: URL, root: URL, app: String) {
            self.format = format; self.source = source; self.root = root; self.app = app
        }
        mutating func block(_ c: ImportPlan.Issue.Code, _ m: String) { blockers.append(.init(c, m)) }
        mutating func warn(_ c: ImportPlan.Issue.Code, _ m: String) { warnings.append(.init(c, m)) }
    }

    struct DiskRef {
        /// As written in the configuration (for messages).
        var reference: String
        var file: URL?
        var member: ImportPlan.ArchiveMember?
        var format: String?
        var label: String
        var readOnly = false
    }

    static func readConfig(_ url: URL, limit: Int = ImportXML.maximumSize) throws -> Data {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular else {
            throw VitrineError.invalidConfig("\(url.lastPathComponent) isn't a regular file")
        }
        guard (attrs[.size] as? NSNumber)?.intValue ?? 0 <= limit else {
            throw VitrineError.invalidConfig("\(url.lastPathComponent) is too large to be a VM configuration")
        }
        return try Data(contentsOf: url)
    }

    static func files(in dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    }

    // MARK: VMware

    static func vmware(_ vmx: URL, root: URL) throws -> Facts {
        var f = Facts(.vmware, source: vmx, root: root, app: "VMware")
        let v = try VMXFile(data: readConfig(vmx, limit: VMXFile.maximumSize))
        let dir = vmx.deletingLastPathComponent()
        f.name = v["displayname"].flatMap { $0.isEmpty ? nil : $0 }
        let guestos = v["guestos"]?.lowercased() ?? ""
        if guestos.contains("darwin") { f.guestOS = .macOS }
        else if guestos.contains("windows") || guestos.hasPrefix("win") || guestos.contains("longhorn") { f.guestOS = .windows }
        else if !guestos.isEmpty && !guestos.hasPrefix("other") { f.guestOS = .linux }
        // Fusion on Apple silicon names every Arm guest "arm-…"; others are x86.
        if guestos.hasPrefix("arm-") || v["guestinfo.detailed.data"]?.contains("architecture='Arm'") == true { f.architecture = .aarch64 }
        else if !guestos.isEmpty { f.architecture = .x86_64 }
        f.firmware = v["firmware"] ?? "bios (not set)"
        f.cpus = v["numvcpus"].flatMap { Int($0) } ?? 1
        f.memoryMiB = v["memsize"].flatMap { UInt64($0) }

        let encrypted = ["encryption.keysafe", "encryption.data", "encryptedvm.guid", "vmx.encryptiontype"]
            .filter { !(v[$0] ?? "").isEmpty }
        if !encrypted.isEmpty {
            f.block(.encrypted, "the VM is encrypted in VMware (\(encrypted.joined(separator: ", "))); remove its encryption in VMware first (Settings ▸ Encryption) and import it again")
        }
        if v.bool("vtpm.present") == true { f.warn(.tpmNotImported, "the VM's virtual TPM isn't imported") }
        if !(v["checkpoint.vmstate"] ?? "").isEmpty
            || files(in: dir).contains(where: { ["vmss", "vmem"].contains($0.pathExtension.lowercased()) }) {
            f.block(.savedState, "the VM is suspended in VMware; resume it and shut it down (not suspend) before importing")
        }
        if files(in: dir).contains(where: { $0.pathExtension.lowercased() == "lck" }) {
            f.block(.running, "the VM looks open in VMware (lock files present); shut it down and quit VMware before importing")
        }
        // <name>.vmsd lists the snapshots (an empty one is normal).
        let stem = vmx.deletingPathExtension().lastPathComponent.lowercased()
        for vmsd in files(in: dir) where vmsd.pathExtension.lowercased() == "vmsd"
            && vmsd.deletingPathExtension().lastPathComponent.lowercased() == stem {
            guard let s = try? VMXFile(data: readConfig(vmsd, limit: VMXFile.maximumSize)) else { continue }
            let count = Int(s["snapshot.numsnapshots"] ?? "") ?? 0
            if count > 0 || s.keys.contains(where: { $0.range(of: #"^snapshot\d+\.uid$"#, options: .regularExpression) != nil }) {
                f.block(.snapshots, "the VM has snapshots in VMware; delete them there first (Snapshots ▸ Delete) so its disks are merged, then import it")
            }
        }
        if v.bool("cleanshutdown") == false {
            f.warn(.cleanShutdown, "VMware recorded no clean shutdown for this VM; its file systems may need checking on first boot")
        }
        if let nvram = v["nvram"], !nvram.isEmpty { f.warn(.nvramNotImported, "the VM's UEFI variables (\(nvram)) aren't imported; the guest boots through its disk's fallback loader") }

        // Disks: <bus><n>:<m>.fileName, present, not a CD.
        let busOrder = ["nvme": 0, "sata": 1, "scsi": 2, "ide": 3]
        var found: [(key: (Int, Int, Int), ref: DiskRef)] = []
        for key in v.keys {
            guard let m = key.wholeMatch(of: #/(ide|sata|scsi|nvme)(\d+):(\d+)\.filename/#) else { continue }
            let bus = String(m.1), unit = "\(bus)\(m.2)", slot = "\(unit):\(m.3)"
            guard v.bool("\(slot).present") == true, v.bool("\(unit).present") != false else { continue }
            let file = v[key] ?? ""
            let type = v["\(slot).devicetype"]?.lowercased() ?? ""
            if type.contains("cdrom") || type.contains("atapi") || file.lowercased() == "auto detect" {
                if !file.isEmpty, file.lowercased() != "auto detect" { f.warn(.mediaSkipped, "left out the CD/DVD image \(file) (\(slot))") }
                continue
            }
            if type.contains("rawdisk") || file.hasPrefix("/dev/") || type == "pt" {
                f.block(.physicalDisk, "\(slot) is a physical disk (\(file)); only disk image files can be imported")
                continue
            }
            var ref = DiskRef(reference: file, format: "vmdk", label: slot)
            if let url = ImportPath.resolve(file, base: dir, root: root) {
                ref.file = url
            } else {
                f.block(.pathOutsideSource, "\(slot)'s disk \(file.debugDescription) is outside the VM's folder; only disks inside it are imported")
            }
            if (file as NSString).lastPathComponent.range(of: #"-\d{6}\.vmdk$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                f.block(.snapshots, "\(slot) uses a snapshot disk (\(file)); delete the VM's snapshots in VMware first so its disks are merged")
            }
            found.append(((busOrder[bus] ?? 9, Int(m.2) ?? 0, Int(m.3) ?? 0), ref))
        }
        f.disks = found.sorted { $0.key < $1.key }.map(\.ref)

        let nics = v.keys.compactMap { $0.wholeMatch(of: #/ethernet(\d+)\.present/#).map { Int($0.1) ?? 0 } }.sorted()
        if !nics.isEmpty, nics.allSatisfy({ v.bool("ethernet\($0).present") == false }) { f.networkDisabled = true }
        if let n = nics.first(where: { v.bool("ethernet\($0).present") == true }) {
            f.mac = v["ethernet\(n).address"].flatMap { $0.isEmpty ? nil : $0 } ?? v["ethernet\(n).generatedaddress"]
        }
        return f
    }

    // MARK: Parallels

    static func parallels(_ pvm: URL) throws -> Facts {
        var f = Facts(.parallels, source: pvm, root: pvm, app: "Parallels Desktop")
        guard let configURL = ImportPath.contained(pvm.appendingPathComponent("config.pvs"), in: pvm) else {
            throw VitrineError.invalidConfig("\(pvm.lastPathComponent) has no config.pvs inside it")
        }
        let x = try ImportXML.parse(readConfig(configURL), what: "config.pvs")
        f.name = x.at("Identification/VmName")?.value
        switch x.at("Settings/General/OsType")?.value {
        case "9": f.guestOS = .linux
        default: break // other values aren't confirmed; the ESP decides (EFI/Microsoft → Windows)
        }
        f.firmware = x.at("Settings/Startup/Bios/EfiEnabled").map { "EfiEnabled=\($0.value)" }
        f.cpus = x.at("Hardware/Cpu/Number").flatMap { Int($0.value) }
        f.memoryMiB = x.at("Hardware/Memory/RAM").flatMap { UInt64($0.value) }
        if x.at("Settings/VmEncryptionInfo/Enabled")?.value == "1" {
            f.block(.encrypted, "the VM is encrypted in Parallels Desktop; decrypt it there first (Configure ▸ Security) and import it again")
        }
        let top = files(in: pvm)
        if top.contains(where: { ["sav", "mem"].contains($0.pathExtension.lowercased()) }) {
            f.block(.savedState, "the VM is suspended in Parallels Desktop; resume it and shut it down before importing")
        }
        if let snaps = ImportPath.contained(pvm.appendingPathComponent("Snapshots.xml"), in: pvm),
           FileManager.default.fileExists(atPath: snaps.path),
           let sx = try? ImportXML.parse(readConfig(snaps), what: "Snapshots.xml"),
           sx.descendants("SavedStateItem").contains(where: { !($0["GUID"] ?? "").isEmpty }) {
            f.block(.snapshots, "the VM has snapshots in Parallels Desktop; delete them there first (Actions ▸ Manage Snapshots) and import it again")
        }
        if top.contains(where: { $0.lastPathComponent == "NVRAM.dat" }) {
            f.warn(.nvramNotImported, "the VM's UEFI variables (NVRAM.dat) aren't imported; the guest boots through its disk's fallback loader")
        }
        for hdd in x.child("Hardware")?.all("Hdd") ?? [] {
            guard hdd.child("Enabled")?.value != "0" else { continue }
            let name = hdd.child("SystemName")?.value ?? ""
            let label = name.isEmpty ? "Hdd \(hdd["id"] ?? "?")" : name
            guard hdd.child("EmulatedType")?.value == "1" else {
                f.block(.physicalDisk, "\(label) is a physical disk or a Boot Camp partition; only disk images can be imported")
                continue
            }
            guard let dir = ImportPath.resolve(name, base: pvm, root: pvm) else {
                f.block(.pathOutsideSource, "the disk \(name.debugDescription) is outside the .pvm bundle; only disks inside it are imported")
                continue
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) else {
                f.block(.diskMissing, "the disk \(name) is missing from the bundle")
                continue
            }
            guard isDir.boolValue, let descURL = ImportPath.contained(dir.appendingPathComponent("DiskDescriptor.xml"), in: pvm),
                  let desc = try? ImportXML.parse(readConfig(descURL), what: "\(name)/DiskDescriptor.xml") else {
                f.block(.diskFormat, "\(name) has no readable DiskDescriptor.xml (an older Parallels disk format); convert it in Parallels Desktop first")
                continue
            }
            if let engine = desc.at("Disk_Parameters/Encryption/Engine")?.value,
               !engine.isEmpty, engine.trimmingCharacters(in: CharacterSet(charactersIn: "{}0-")).isEmpty == false {
                f.block(.encrypted, "the disk \(name) is encrypted; decrypt the VM in Parallels Desktop first")
                continue
            }
            let storages = desc.at("StorageData")?.all("Storage") ?? []
            let shots = desc.at("Snapshots")?.all("Shot") ?? []
            if shots.count > 1 || storages.contains(where: { $0.all("Image").count > 1 }) {
                f.block(.snapshots, "the disk \(name) has snapshots; delete the VM's snapshots in Parallels Desktop first and import it again")
                continue
            }
            guard storages.count == 1, let image = storages[0].child("Image"), let file = image.child("File")?.value else {
                f.block(.diskFormat, "the disk \(name) is split into \(storages.count) parts, which can't be imported; merge it in Parallels Desktop first (or export the VM)")
                continue
            }
            var ref = DiskRef(reference: file, label: name)
            switch image.child("Type")?.value {
            case "Compressed": ref.format = "parallels"
            case "Plain": ref.format = "raw"
            case let other:
                f.block(.diskFormat, "the disk \(name) has image type \(other ?? "?"), which can't be imported")
                continue
            }
            guard let url = ImportPath.resolve(file, base: dir, root: pvm) else {
                f.block(.pathOutsideSource, "the disk image \(file.debugDescription) is outside the .pvm bundle")
                continue
            }
            ref.file = url
            f.disks.append(ref)
        }
        for nic in x.child("Hardware")?.all("NetworkAdapter") ?? [] where nic.child("Enabled")?.value != "0" {
            f.mac = nic.child("MAC")?.value
            break
        }
        if (x.child("Hardware")?.all("NetworkAdapter") ?? []).allSatisfy({ $0.child("Enabled")?.value == "0" }) {
            f.networkDisabled = true
        }
        return f
    }

    // MARK: VirtualBox

    static func virtualBox(_ vbox: URL, root: URL) throws -> Facts {
        var f = Facts(.virtualBox, source: vbox, root: root, app: "VirtualBox")
        let x = try ImportXML.parse(readConfig(vbox), what: vbox.lastPathComponent)
        if x.name == "MachineEncrypted" || !x.descendants("MachineEncrypted").isEmpty {
            f.block(.encrypted, "the VM is encrypted in VirtualBox; remove its encryption there first and import it again")
            return f
        }
        guard let machine = x.child("Machine") else {
            throw VitrineError.invalidConfig("\(vbox.lastPathComponent) has no <Machine>")
        }
        vboxMachine(machine, base: vbox.deletingLastPathComponent(), into: &f, disks: true)
        return f
    }

    /// Reads a VirtualBox <Machine> (a .vbox file's, or the one embedded in an OVF it exported).
    /// Only the current state counts: <Snapshot> subtrees carry older copies of the hardware.
    static func vboxMachine(_ machine: ImportXML, base: URL, into f: inout Facts, disks: Bool) {
        f.name = f.name ?? machine["name"]
        let ostype = machine["OSType"] ?? ""
        if ostype.lowercased().hasPrefix("windows") { f.guestOS = .windows }
        else if ostype.lowercased().hasPrefix("macos") { f.guestOS = .macOS }
        else if !ostype.isEmpty && !ostype.lowercased().hasPrefix("other") { f.guestOS = .linux }
        let hw = machine.child("Hardware")
        let platform = machine.child("Platform") ?? hw?.child("Platform")
        switch platform?["architecture"]?.lowercased() {
        case "arm": f.architecture = .aarch64
        case "x86": f.architecture = .x86_64
        default: f.architecture = ostype.lowercased().hasSuffix("_arm64") ? .aarch64 : (ostype.isEmpty ? nil : .x86_64)
        }
        if !(machine["stateFile"] ?? "").isEmpty {
            f.block(.savedState, "the VM has a saved state in VirtualBox; start it and shut it down (or discard the saved state) before importing")
        }
        let current = machine["currentSnapshot"] ?? ""
        if machine.child("Snapshot") != nil || (!current.isEmpty && current.trimmingCharacters(in: CharacterSet(charactersIn: "{}0-")).isEmpty == false) {
            f.block(.snapshots, "the VM has snapshots in VirtualBox; delete them there first (Snapshots ▸ Delete) so its disks are merged, then import it")
        }
        f.memoryMiB = (hw?.child("Memory")?["RAMSize"]).flatMap { UInt64($0) } ?? f.memoryMiB
        if let n = (platform?.child("CPU")?["count"] ?? hw?.child("CPU")?["count"]).flatMap({ Int($0) }) { f.cpus = n }
        else if f.cpus == nil, hw?.child("CPU") != nil || platform?.child("CPU") != nil { f.cpus = 1 }
        if let fw = hw?.child("Firmware")?["type"] { f.firmware = fw } else if f.firmware == nil { f.firmware = "BIOS (not set)" }
        let adapters = (hw?.child("Network")?.all("Adapter") ?? []).sorted { Int($0["slot"] ?? "") ?? 0 < Int($1["slot"] ?? "") ?? 0 }
        if let nic = adapters.first(where: { $0["enabled"] != "false" && $0["MACAddress"] != nil }) { f.mac = nic["MACAddress"] }
        guard disks else { return }

        // Media: uuid → (node, parent uuid). Nested <HardDisk>s are differencing children.
        var media: [String: (node: ImportXML, parent: String?)] = [:]
        func walk(_ n: ImportXML, parent: String?) {
            for d in n.all("HardDisk") {
                let id = (d["uuid"] ?? "").lowercased()
                media[id] = (d, parent)
                walk(d, parent: id)
            }
        }
        if let reg = machine.at("MediaRegistry/HardDisks") { walk(reg, parent: nil) }
        let controllers = hw?.child("StorageControllers") ?? machine.child("StorageControllers")
        for c in controllers?.all("StorageController") ?? [] {
            let devices = c.all("AttachedDevice").sorted {
                (Int($0["port"] ?? "") ?? 0, Int($0["device"] ?? "") ?? 0) < (Int($1["port"] ?? "") ?? 0, Int($1["device"] ?? "") ?? 0)
            }
            for dev in devices {
                let slot = "\(c["name"] ?? "controller") port \(dev["port"] ?? "?")"
                guard dev["type"] == "HardDisk" else {
                    if dev.child("Image") != nil { f.warn(.mediaSkipped, "left out the \(dev["type"] ?? "removable") image attached at \(slot)") }
                    continue
                }
                guard let id = dev.child("Image")?["uuid"]?.lowercased(), let m = media[id] else {
                    f.block(.diskMissing, "the disk at \(slot) isn't in the VM's media registry (it may be registered globally in VirtualBox); attach it to this VM's folder and import again")
                    continue
                }
                let location = m.node["location"] ?? ""
                if m.parent != nil || !m.node.all("HardDisk").isEmpty {
                    f.block(.snapshots, "the disk at \(slot) is part of a snapshot chain (differencing images); delete the VM's snapshots in VirtualBox first so its disks are merged")
                    continue
                }
                if m.node.all("Property").contains(where: { ($0["name"] ?? "").hasPrefix("CRYPT/") }) {
                    f.block(.encrypted, "the disk \(location) is encrypted in VirtualBox; remove its encryption there first")
                    continue
                }
                if m.node.all("Property").contains(where: { $0["name"] == "RawDrive" }) {
                    f.block(.physicalDisk, "the disk \(location) gives the VM a physical drive; only disk images can be imported")
                    continue
                }
                var ref = DiskRef(reference: location, label: slot)
                switch (m.node["format"] ?? "").lowercased() {
                case "vdi": ref.format = "vdi"
                case "vmdk": ref.format = "vmdk"
                case "vhd": ref.format = "vpc"
                case "parallels": ref.format = "parallels"
                case "qcow": ref.format = "qcow"
                case "qed": ref.format = "qed"
                default:
                    f.block(.diskFormat, "the disk \(location) is in \(m.node["format"] ?? "an unknown") format, which can't be imported")
                    continue
                }
                guard let url = ImportPath.resolve(location, base: base, root: f.root) else {
                    f.block(.pathOutsideSource, "the disk \(location.debugDescription) is outside the VM's folder; move it there in VirtualBox (Media Manager ▸ Move) and import again")
                    continue
                }
                ref.file = url
                f.disks.append(ref)
            }
        }
    }

    // MARK: OVF / OVA

    /// Reads an OVF descriptor. `lookup` finds a referenced file: in the descriptor's folder, or
    /// among an OVA's members.
    static func ovf(_ data: Data, into f: inout Facts, lookup: (String) -> (url: URL, member: ImportPlan.ArchiveMember?)?) throws {
        let env = try ImportXML.parse(data, what: "the OVF descriptor")
        guard env.name == "Envelope" else { throw VitrineError.invalidConfig("not an OVF descriptor (no <Envelope>)") }
        var files: [String: ImportXML] = [:]
        for file in env.child("References")?.all("File") ?? [] { if let id = file["id"] { files[id] = file } }
        var diskDecls: [String: ImportXML] = [:]
        for d in env.descendants("DiskSection").flatMap({ $0.all("Disk") }) { if let id = d["diskId"] { diskDecls[id] = d } }
        if !env.descendants("VirtualSystemCollection").isEmpty || env.descendants("VirtualSystem").count != 1 {
            f.block(.multipleVMs, "the package holds \(env.descendants("VirtualSystem").count) virtual machines; only single-VM packages can be imported")
            return
        }
        let vs = env.descendants("VirtualSystem")[0]
        f.name = vs.child("Name")?.value.nilIfEmpty ?? vs["id"]
        if let machine = vs.child("Machine") { // VirtualBox's own description, more precise
            vboxMachine(machine, base: f.root, into: &f, disks: false)
            f.app = "VirtualBox"
        }
        let os = vs.child("OperatingSystemSection")
        let osType = (os?["osType"] ?? os?.child("Description")?.value ?? "").lowercased()
        if f.guestOS == nil, !osType.isEmpty {
            if osType.contains("windows") || osType.hasPrefix("win") { f.guestOS = .windows }
            else if osType.contains("darwin") { f.guestOS = .macOS }
            else if !osType.hasPrefix("other") { f.guestOS = .linux }
        }
        if f.architecture == nil, osType.contains("arm") || osType.contains("aarch64") { f.architecture = .aarch64 }
        guard let hw = vs.child("VirtualHardwareSection") else {
            f.block(.unreadableConfig, "the OVF descriptor has no virtual hardware section")
            return
        }
        for c in hw.children where (c.name == "Config" || c.name == "ExtraConfig") && c["key"]?.lowercased() == "firmware" {
            f.firmware = f.firmware ?? c["value"]
        }
        var diskIDs: [String] = []
        for item in hw.children where ["Item", "StorageItem", "EthernetPortItem"].contains(item.name) {
            guard let type = item.child("ResourceType")?.value else { continue }
            let quantity = item.child("VirtualQuantity").flatMap { UInt64($0.value) }
            switch type {
            case "3": if let q = quantity { f.cpus = Int(q) }
            case "4":
                if let q = quantity, let mib = mebibytes(q, units: item.child("AllocationUnits")?.value ?? "MegaBytes") { f.memoryMiB = mib }
            case "17":
                guard let host = item.child("HostResource")?.value else { continue }
                let id = host.components(separatedBy: "/").last ?? host
                if host.contains("/disk/") { diskIDs.append(id) }
                else { f.block(.diskFormat, "disk \(item.child("ElementName")?.value ?? id) refers to \(host), which isn't a disk in the package") }
            case "15", "16":
                if item.child("HostResource") != nil { f.warn(.mediaSkipped, "left out the CD/DVD image attached as \(item.child("ElementName")?.value ?? "a CD drive")") }
            case "10":
                if f.mac == nil, let a = item.child("Address")?.value, !a.isEmpty { f.mac = a }
            case "32768" where item.child("Caption")?.value == "NVRAM":
                f.warn(.nvramNotImported, "the VM's UEFI variables (NVRAM) aren't imported; the guest boots through its disk's fallback loader")
            default: break
            }
        }
        for id in diskIDs {
            guard let d = diskDecls[id] else { f.block(.diskMissing, "disk \(id) isn't declared in the package"); continue }
            guard let ref = d["fileRef"], let file = files[ref], let href = file["href"] else {
                f.block(.diskFormat, "disk \(id) is an empty disk to be created on import, which isn't supported")
                continue
            }
            if !(file["compression"] ?? "").isEmpty || file["chunkSize"] != nil {
                f.block(.diskFormat, "the disk file \(href) is compressed or split (\(file["compression"] ?? "chunked")), which isn't supported")
                continue
            }
            let fmt = (d["format"] ?? "").lowercased()
            var r = DiskRef(reference: href, label: id)
            if fmt.contains("vmdk") { r.format = "vmdk" }
            else if fmt.contains("qcow") { r.format = "qcow2" }
            else if fmt.contains("vhd") { r.format = "vpc" }
            else {
                f.block(.diskFormat, "the disk \(href) is in a format the package calls \(fmt.isEmpty ? "nothing" : fmt), which can't be imported")
                continue
            }
            guard let found = lookup(href) else {
                f.block(.pathOutsideSource, "the disk \(href.debugDescription) isn't a file of the package (missing, or a path outside it)")
                continue
            }
            r.file = found.url
            r.member = found.member
            f.disks.append(r)
        }
        if diskIDs.isEmpty { f.block(.noDisks, "the package's virtual machine has no disk") }
    }

    /// OVF AllocationUnits ("MegaBytes", "byte * 2^20", "GigaBytes", …) applied to `q`, in MiB.
    static func mebibytes(_ q: UInt64, units raw: String) -> UInt64? {
        let u = raw.lowercased().replacingOccurrences(of: " ", with: "")
        let bytesPer: Double
        switch u {
        case "megabytes", "mb", "mbytes", "mib": bytesPer = Double(1 << 20)
        case "gigabytes", "gb", "gbytes", "gib": bytesPer = Double(1 << 30)
        case "kilobytes", "kb": bytesPer = 1024
        case "byte", "bytes": bytesPer = 1
        default:
            guard let m = u.wholeMatch(of: #/byte\*(\d+)\^(\d+)/#), let base = Double(m.1), let exp = Double(m.2) else { return nil }
            bytesPer = pow(base, exp)
        }
        let mib = Double(q) * bytesPer / Double(1 << 20)
        return mib.isFinite && mib >= 1 && mib < 1e9 ? UInt64(mib) : nil
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
