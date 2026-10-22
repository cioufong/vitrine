import Foundation
import Virtualization
import VitrineCore

/// Creates a new macOS VM bundle from a restore image and runs the installer.
public final class MacInstaller {
    public struct Options {
        public var name: String
        public var cpuCount: Int?
        public var memoryMiB: UInt64?
        public var diskBytes: UInt64 = 80 << 30
        public var diskFormat: DiskImageFormat = DiskImage.preferredFormat
        public var display = VMConfig.DisplayConfig()
        public var account: (fullName: String, username: String, password: String)?
        public var bundleURL: URL?
        public init(name: String) { self.name = name }
    }

    public enum Phase: Equatable {
        case preparing
        case installing(Double)
        case done
    }

    public init() {}

    /// Builds the bundle (hardware model, aux storage, disk, config) for `restoreImage`.
    public func createBundle(options: Options, restoreImage: VZMacOSRestoreImage) throws -> VMBundle {
        guard let req = restoreImage.mostFeaturefulSupportedConfiguration else {
            throw VitrineError.unsupported("restore image \(restoreImage.buildVersion) cannot run on this Mac")
        }
        guard req.hardwareModel.isSupported else {
            throw VitrineError.unsupported("hardware model of \(restoreImage.buildVersion) not supported on this host")
        }
        let hostCPUs = ProcessInfo.processInfo.processorCount
        let cpus = max(options.cpuCount ?? max(2, hostCPUs / 2), req.minimumSupportedCPUCount)
        let memMiB = max(options.memoryMiB ?? 8192, req.minimumSupportedMemorySize >> 20)

        var config = VMConfig(name: options.name, guestOS: .macOS, cpuCount: cpus, memoryMiB: memMiB)
        config.display = options.display
        let v = restoreImage.operatingSystemVersion
        config.installedOS = "macOS \(v.majorVersion).\(v.minorVersion)\(v.patchVersion > 0 ? ".\(v.patchVersion)" : "") (\(restoreImage.buildVersion))"
        if let acct = options.account {
            config.account = .init(fullName: acct.fullName, username: acct.username)
        }

        return try VMBundle.create(at: options.bundleURL ?? VMLibrary.bundleURL(named: options.name), config: config) { bundle, config in
            try req.hardwareModel.dataRepresentation.write(to: bundle.hardwareModelURL)
            _ = try VZMacAuxiliaryStorage(creatingStorageAt: bundle.auxiliaryStorageURL,
                                          hardwareModel: req.hardwareModel, options: [])
            try VZMacMachineIdentifier().dataRepresentation.write(to: bundle.machineIdentifierURL)
            config.disks = [.init(path: try bundle.createMainDisk(sizeBytes: options.diskBytes, format: options.diskFormat))]
            if let acct = options.account {
                try GuestCredentialStore.setPassword(acct.password, in: bundle)
            }
        }
    }

    /// Installs macOS from `ipsw` into an already-created bundle.
    @MainActor
    public func install(bundle: VMBundle, ipsw: URL, progress: @escaping (Phase) -> Void) async throws {
        progress(.preparing)
        let config = try bundle.loadConfig()
        let vzConfig = try ConfigurationBuilder.build(bundle: bundle, config: config)
        let vm = VZVirtualMachine(configuration: vzConfig)
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw)
        let observation = installer.progress.observe(\.fractionCompleted, options: [.new]) { p, _ in
            let fraction = p.fractionCompleted
            DispatchQueue.main.async { progress(.installing(fraction)) }
        }
        defer { observation.invalidate() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            installer.install { cont.resume(with: $0) }
        }
        if vm.canStop { try? await vm.stop() }
        progress(.done)
    }
}
