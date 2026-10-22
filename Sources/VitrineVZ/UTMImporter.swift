import Foundation
import VitrineCore
import VitrineQEMU

/// Imports UTM virtual machines (`*.utm` bundles, configuration version 4): Virtualization.framework
/// ("Apple") VMs with macOS or Linux guests, and QEMU VMs for aarch64/x86_64 Linux and Windows.
/// Disks inside the bundle are copied (APFS clones for raw images, converted for qcow2); the
/// original bundle is not changed. Settings UTM keeps outside the bundle (external drives, shared
/// folder paths) can't be imported and are reported.
public enum UTMImporter {
    public struct Result {
        public var bundle: VMBundle
        public var notes: [String]
    }

    @discardableResult
    public static func importBundle(_ url: URL, name: String?) throws -> VMBundle {
        try importVM(url, name: name).bundle
    }

    public static func importVM(_ src: URL, name: String?) throws -> Result {
        let plistURL = src.appendingPathComponent("config.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw VitrineError.invalidConfig("\(src.lastPathComponent) has no readable config.plist")
        }
        guard let backend = root["Backend"] as? String else {
            throw VitrineError.unsupported("\(src.lastPathComponent) is in UTM's pre-4.0 format; open and save it in a current UTM first")
        }
        guard (root["ConfigurationVersion"] as? Int) == 4 else {
            throw VitrineError.unsupported("UTM configuration version \(root["ConfigurationVersion"] ?? "?") isn't supported (expected 4)")
        }
        let info = root["Information"] as? [String: Any] ?? [:]
        let vmName = name ?? (info["Name"] as? String) ?? src.deletingPathExtension().lastPathComponent
        let system = root["System"] as? [String: Any] ?? [:]
        let bundleDir = src.resolvingSymlinksInPath().standardizedFileURL
        let dataDir = bundleDir.appendingPathComponent("Data", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        guard dataDir.path.hasPrefix(bundleDir.path + "/") else {
            throw VitrineError.invalidConfig("UTM Data directory must stay inside the bundle")
        }
        func source(_ path: String) throws -> URL {
            let file = dataDir.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
                  !(path as NSString).pathComponents.contains(".."),
                  file.path.hasPrefix(dataDir.path + "/") else {
                throw VitrineError.invalidConfig("UTM source \(path) must stay inside its Data directory")
            }
            return file
        }
        var notes: [String] = []

        var config = VMConfig(name: vmName, guestOS: .linux)
        if let n = system["CPUCount"] as? Int, n > 0 { config.cpuCount = min(n, ProcessInfo.processInfo.processorCount) }
        if let mib = system["MemorySize"] as? Int, mib > 0 { config.memoryMiB = UInt64(mib) }
        if let mac = ((root["Network"] as? [[String: Any]])?.first?["MacAddress"] as? String)?.lowercased() {
            config.network.macAddress = mac
        }
        if (root["Network"] as? [[String: Any]])?.isEmpty == true { config.network.mode = .none }
        let utmNetwork = (root["Network"] as? [[String: Any]])?.first
        switch utmNetwork?["Mode"] as? String {
        case "Host": config.network.mode = .hostOnly
        case "Bridged":
            let interface = (utmNetwork?["BridgeInterface"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "en0"
            config.network.mode = .bridged
            config.network.bridgeInterface = interface
            if BridgeSockets.socket(for: interface) == nil {
                notes.append("bridged to \(interface); install the bridge helper in Settings ▸ Networks before starting the VM")
            }
        default: break
        }

        // Platform files for the new bundle: (destination in our bundle, data).
        var platformFiles: [(String, Data)] = []
        var copies: [(from: URL, to: String, convert: Bool)] = []

        switch backend {
        case "Apple":
            config.backend = .vz
            let boot = system["Boot"] as? [String: Any] ?? [:]
            switch boot["OperatingSystem"] as? String {
            case "macOS":
                config.guestOS = .macOS
                let mac = system["MacPlatform"] as? [String: Any] ?? [:]
                guard let model = mac["HardwareModel"] as? Data, let machine = mac["MachineIdentifier"] as? Data else {
                    throw VitrineError.invalidConfig("the macOS VM has no hardware model or machine identifier")
                }
                let aux = try source(mac["AuxiliaryStoragePath"] as? String ?? "AuxiliaryStorage")
                guard FileManager.default.fileExists(atPath: aux.path) else {
                    throw VitrineError.fileNotFound("auxiliary storage \(aux.lastPathComponent)")
                }
                platformFiles += [("hardware-model.bin", model), ("machine-identifier.bin", machine)]
                copies.append((aux, "aux-storage.bin", false))
            case "Linux":
                config.guestOS = .linux
                if let id = (system["GenericPlatform"] as? [String: Any])?["machineIdentifier"] as? Data {
                    platformFiles.append(("machine-identifier.bin", id))
                }
                if boot["UEFIBoot"] as? Bool ?? true {
                    config.boot = .efi
                    let vars = try source(boot["EfiVariableStoragePath"] as? String ?? "efi_vars.fd")
                    if FileManager.default.fileExists(atPath: vars.path) { copies.append((vars, "nvram.bin", false)) }
                } else {
                    guard let kernel = boot["LinuxKernelPath"] as? String else {
                        throw VitrineError.invalidConfig("the Linux VM boots a kernel but names none")
                    }
                    copies.append((try source(kernel), "vmlinuz", false))
                    var initrd: String?
                    if let i = boot["LinuxInitialRamdiskPath"] as? String {
                        copies.append((try source(i), "initrd", false)); initrd = "initrd"
                    }
                    config.boot = .kernel(kernel: "vmlinuz", initrd: initrd, commandLine: boot["LinuxCommandLine"] as? String ?? "console=hvc0")
                }
                if (root["Virtualization"] as? [String: Any])?["Rosetta"] as? Bool == true { config.features.rosetta = true }
            default:
                throw VitrineError.unsupported("the UTM VM has no supported operating system set")
            }
            if let d = (root["Display"] as? [[String: Any]])?.first, let w = d["WidthPixels"] as? Int, let h = d["HeightPixels"] as? Int {
                config.display = .init(widthPixels: w, heightPixels: h, pixelsPerInch: d["PixelsPerInch"] as? Int ?? 110)
            }
        case "QEMU":
            config.backend = .qemu
            switch system["Architecture"] as? String {
            case "aarch64": config.architecture = .aarch64
            case "x86_64": config.architecture = .x86_64
            case let other: throw VitrineError.unsupported("QEMU guests of architecture \(other ?? "?") aren't supported (aarch64 and x86_64 are)")
            }
            let icon = (info["IconCustom"] as? Bool == true) ? "" : (info["Icon"] as? String ?? "").lowercased()
            config.guestOS = icon.hasPrefix("windows") ? .windows : .linux
            if icon.isEmpty || !(icon.hasPrefix("windows") || ["linux", "debian", "ubuntu", "fedora", "arch", "alpine", "centos", "kali", "mint", "opensuse", "redhat", "gentoo", "manjaro", "elementary"].contains(where: icon.hasPrefix)) {
                notes.append("assumed a \(config.guestOS == .windows ? "Windows" : "Linux") guest (UTM stores no OS type); change it with the VM's configuration if wrong")
            }
            if config.guestOS == .linux { config.boot = .efi }
            let qemu = root["QEMU"] as? [String: Any] ?? [:]
            if qemu["UEFIBoot"] as? Bool == false {
                notes.append("the VM boots with legacy BIOS; Vitrine starts QEMU guests with UEFI, so a BIOS-only system won't boot")
            }
            let vars = try source("efi_vars.fd")
            if FileManager.default.fileExists(atPath: vars.path) { copies.append((vars, "efivars.fd", false)) }
            let tpm = try source("tpmdata")
            if FileManager.default.fileExists(atPath: tpm.path) {
                copies.append((tpm, "tpm/tpm2-00.permall", false))
                notes.append("copied UTM's TPM state; this carry-over is untested, so BitLocker or Windows Hello may ask for recovery")
            }
            if let sharing = root["Sharing"] as? [String: Any], (sharing["DirectoryShareMode"] as? String ?? "None") != "None" {
                notes.append("UTM keeps the shared folder's path outside the bundle; add it again under Configuration ▸ Sharing")
            }
        default:
            throw VitrineError.unsupported("unknown UTM backend \(backend)")
        }

        // Drives in the bundle become disks; CDs and external drives are left out.
        var diskIndex = 0
        for drive in root["Drive"] as? [[String: Any]] ?? [] {
            guard let image = drive["ImageName"] as? String else {
                notes.append("skipped an external drive (its path is kept outside the UTM bundle)")
                continue
            }
            let type = drive["ImageType"] as? String ?? "Disk"
            guard type == "Disk" else {
                if type == "CD" { notes.append("left out the CD image \(image); attach it again if you still need it") }
                continue
            }
            let file = try source(image)
            let layers = (try? FileManager.default.contentsOfDirectory(atPath: dataDir.path))?.filter { $0.hasPrefix(image + ".") && $0.hasSuffix(".asif") } ?? []
            guard layers.isEmpty else {
                throw VitrineError.unsupported("\(image) has UTM snapshot layers; delete the VM's snapshots in UTM (or restore and remove them) before importing")
            }
            diskIndex += 1
            let name = diskIndex == 1 ? "disk.img" : "disk\(diskIndex).img"
            copies.append((file, name, true))
            config.disks.append(.init(path: name, readOnly: drive["ReadOnly"] as? Bool ?? false,
                                      interface: config.effectiveBackend == .qemu ? .nvme : .virtio))
        }
        guard !config.disks.isEmpty else { throw VitrineError.invalidConfig("the UTM VM has no disk inside its bundle") }

        let url = VMLibrary.bundleURL(named: vmName)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw VitrineError.invalidConfig("a VM named \(vmName) already exists") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bundle = try VMBundle.create(at: url, config: config)
        do {
            for (rel, data) in platformFiles { try data.write(to: bundle.resolve(rel)) }
            for c in copies {
                let dest = bundle.resolve(c.to)
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if c.convert { try DiskImport.convert(c.from, to: dest) } else { try DiskImage.clone(c.from, to: dest) }
            }
            try config.validate(bundle: bundle)
            try bundle.saveConfig(config)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return Result(bundle: bundle, notes: notes)
    }
}
