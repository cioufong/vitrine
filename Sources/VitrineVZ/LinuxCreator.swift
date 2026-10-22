import Foundation
import VitrineCore

/// Creates Linux VM bundles: UEFI + installer ISO, or direct kernel boot.
public enum LinuxCreator {
    public struct Options {
        public var name: String
        public var cpuCount = max(2, ProcessInfo.processInfo.processorCount / 2)
        public var memoryMiB: UInt64 = 4096
        public var diskBytes: UInt64 = 64 << 30
        public var diskFormat: DiskImageFormat = DiskImage.preferredFormat
        public var installISO: URL?
        public var kernel: (kernel: URL, initrd: URL?, commandLine: String)?
        public var display = VMConfig.DisplayConfig(widthPixels: 1920, heightPixels: 1200, pixelsPerInch: 110)
        public var rosetta = false
        /// `.qemu` (required for x86_64) gets a raw disk whatever `diskFormat` says: QEMU can't
        /// open ASIF images.
        public var backend: VMConfig.Backend = .vz
        public var architecture: VMConfig.Architecture = .aarch64
        public var bundleURL: URL?
        public init(name: String) { self.name = name }
    }

    @discardableResult
    public static func create(_ o: Options) throws -> VMBundle {
        var config = VMConfig(name: o.name, guestOS: .linux, cpuCount: o.cpuCount, memoryMiB: o.memoryMiB)
        config.display = o.display
        config.features.rosetta = o.rosetta
        if let k = o.kernel {
            config.boot = .kernel(kernel: k.kernel.path, initrd: k.initrd?.path, commandLine: k.commandLine)
        } else {
            config.boot = .efi
        }
        config.installMedia = o.installISO?.path
        if o.backend == .qemu {
            config.backend = .qemu
            config.architecture = o.architecture
        }
        return try VMBundle.create(at: o.bundleURL ?? VMLibrary.bundleURL(named: o.name), config: config) { bundle, config in
            let disk = try bundle.createMainDisk(sizeBytes: o.diskBytes, format: o.backend == .qemu ? .raw : o.diskFormat)
            config.disks = [.init(path: disk)]
            try config.validate(bundle: bundle)
        }
    }
}
