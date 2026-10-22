import Foundation
import VitrineCore
import VitrineQEMU

/// Creates Vitrine VMs from other tools' disks and bundles.
public enum VMImporter {
    public struct DiskOptions {
        public var name: String
        public var guestOS: VMConfig.GuestOS = .linux
        public var architecture: VMConfig.Architecture = .aarch64
        public var cpuCount = max(2, ProcessInfo.processInfo.processorCount / 2)
        public var memoryMiB: UInt64 = 4096
        public init(name: String) { self.name = name }
    }

    /// A new VM booting (UEFI) from a copy of `disk` converted to raw. Arm Linux runs on
    /// Virtualization.framework; Windows and x86_64 guests on QEMU.
    @discardableResult
    public static func importDisk(_ disk: URL, _ o: DiskOptions) throws -> VMBundle {
        var config = VMConfig(name: o.name, guestOS: o.guestOS, cpuCount: o.cpuCount, memoryMiB: o.memoryMiB)
        guard o.guestOS != .macOS else {
            throw VitrineError.unsupported("a macOS disk alone can't be imported (it needs its platform identity); import the whole VM bundle instead")
        }
        config.architecture = o.architecture
        config.backend = (o.guestOS == .linux && o.architecture == .aarch64) ? .vz : .qemu
        if o.guestOS == .linux { config.boot = .efi }
        config.disks = [.init(path: "disk.img", interface: config.effectiveBackend == .qemu ? .nvme : .virtio)]
        let url = VMLibrary.bundleURL(named: o.name)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw VitrineError.invalidConfig("a VM named \(o.name) already exists") }
        return try VMBundle.create(at: url, config: config) { bundle, config in
            try DiskImport.convert(disk, to: bundle.resolve("disk.img"))
            try config.validate(bundle: bundle)
        }
    }

    /// Adds a copy of `disk` (converted to raw) to a stopped VM as its next disk.
    @discardableResult
    public static func addDisk(_ disk: URL, to bundle: VMBundle, readOnly: Bool = false) throws -> String {
        try bundle.withExclusiveLock {
            var config = try bundle.loadConfig()
            if bundle.hasSavedState {
                throw VitrineError.invalidConfig("shut \(bundle.name) down (not suspend) before adding a disk")
            }
            var n = config.disks.count + 1
            var name = "disk\(n).img"
            while FileManager.default.fileExists(atPath: bundle.resolve(name).path) { n += 1; name = "disk\(n).img" }
            try DiskImport.convert(disk, to: bundle.resolve(name))
            config.disks.append(.init(path: name, readOnly: readOnly, interface: config.effectiveBackend == .qemu ? .nvme : .virtio))
            do {
                try config.validate(bundle: bundle)
                try bundle.saveConfig(config)
            } catch {
                try? FileManager.default.removeItem(at: bundle.resolve(name))
                throw error
            }
            return name
        }
    }
}
