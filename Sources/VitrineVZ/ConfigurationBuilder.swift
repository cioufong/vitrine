import Foundation
import Virtualization
import VitrineCore
import VitrineAgentProtocol

/// Translates a `VMConfig` + bundle into a `VZVirtualMachineConfiguration`.
public enum ConfigurationBuilder {
    /// virtio-console port name the macOS/Linux SPICE agent looks for (clipboard).
    static let spicePortName = VZSpiceAgentPortAttachment.spiceAgentPortName

    /// virtiofs tag Linux guests mount shared folders from: `mount -t virtiofs vitrine /mnt/vitrine`.
    public static let linuxShareTag = "vitrine"
    public static let rosettaTag = "rosetta"

    /// - Parameter usbController: add an xHCI controller for hot-plugging USB drives and devices
    ///   (macOS 15+). A saved state made without one can only be restored without one.
    /// - Parameter networkAttachment: what the network adapter is plugged into (`NetworkLink`);
    ///   nil is the Mac's shared NAT network.
    public static func build(bundle: VMBundle, config: VMConfig, usbController: Bool = true,
                             networkAttachment: VZNetworkDeviceAttachment? = nil) throws -> VZVirtualMachineConfiguration {
        try config.validate(bundle: bundle)
        let vz = VZVirtualMachineConfiguration()
        vz.cpuCount = clamp(config.cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount,
                            VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        vz.memorySize = clamp(config.memoryMiB << 20, VZVirtualMachineConfiguration.minimumAllowedMemorySize,
                              VZVirtualMachineConfiguration.maximumAllowedMemorySize)
        switch config.guestOS {
        case .macOS:
            vz.platform = try macPlatform(bundle: bundle)
            vz.bootLoader = VZMacOSBootLoader()
            // Paravirtualized Metal GPU.
            let graphics = VZMacGraphicsDeviceConfiguration()
            graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: config.display.widthPixels,
                                                                   heightInPixels: config.display.heightPixels,
                                                                   pixelsPerInch: config.display.pixelsPerInch)]
            vz.graphicsDevices = [graphics]
            vz.keyboards = [VZMacKeyboardConfiguration()]
            vz.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]
        case .linux:
            vz.platform = try linuxPlatform(bundle: bundle, nested: config.features.nestedVirtualization)
            vz.bootLoader = try linuxBootLoader(config: config, bundle: bundle)
            let graphics = VZVirtioGraphicsDeviceConfiguration()
            graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: config.display.widthPixels,
                                                                      heightInPixels: config.display.heightPixels)]
            vz.graphicsDevices = [graphics]
            vz.keyboards = [VZUSBKeyboardConfiguration()]
            vz.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
            // Serial console (hvc0) mirrored to console.log for headless debugging.
            vz.serialPorts = [try serialConsole(bundle: bundle)]
        case .windows:
            throw VitrineError.unsupported("Windows guests run on the QEMU backend")
        }

        vz.storageDevices = try config.disks.map { try storageDevice(for: $0, guestOS: config.guestOS, bundle: bundle) }
        if config.guestOS == .linux, let media = config.installMedia {
            let iso = try VZDiskImageStorageDeviceAttachment(url: bundle.resolve(media), readOnly: true)
            vz.storageDevices.append(VZUSBMassStorageDeviceConfiguration(attachment: iso))
        }

        if config.network.isConnected {
            let net = VZVirtioNetworkDeviceConfiguration()
            net.attachment = networkAttachment ?? VZNATNetworkDeviceAttachment()
            if let mac = VZMACAddress(string: config.network.macAddress) { net.macAddress = mac }
            vz.networkDevices = [net]
        }

        if config.features.sound {
            let sound = VZVirtioSoundDeviceConfiguration()
            let out = VZVirtioSoundDeviceOutputStreamConfiguration()
            out.sink = VZHostAudioOutputStreamSink()
            var streams: [VZVirtioSoundDeviceStreamConfiguration] = [out]
            if config.features.microphone {
                let input = VZVirtioSoundDeviceInputStreamConfiguration()
                input.source = VZHostAudioInputStreamSource()
                streams.append(input)
            }
            sound.streams = streams
            vz.audioDevices = [sound]
        }

        vz.directorySharingDevices = try directoryShares(config: config, bundle: bundle)
        vz.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        vz.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        vz.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        if usbController, #available(macOS 15, *) {
            vz.usbControllers = [VZXHCIControllerConfiguration()]
        }

        if config.features.clipboard {
            let console = VZVirtioConsoleDeviceConfiguration()
            let port = VZVirtioConsolePortConfiguration()
            port.name = spicePortName
            let spice = VZSpiceAgentPortAttachment()
            spice.sharesClipboard = true
            port.attachment = spice
            console.ports[0] = port
            vz.consoleDevices = [console]
        }

        do { try vz.validate() } catch {
            throw VitrineError.backend("configuration rejected by Virtualization.framework: \(error.localizedDescription)")
        }
        return vz
    }

    /// The virtiofs device for shared folders. Exposed so shares can be swapped while running.
    public static func directoryShare(config: VMConfig, bundle: VMBundle) -> VZDirectoryShare {
        var dirs: [String: VZSharedDirectory] = [:]
        for s in config.shares {
            dirs[s.name] = VZSharedDirectory(url: bundle.resolve(s.hostPath), readOnly: s.readOnly)
        }
        // Drag-and-drop staging area, always present.
        try? FileManager.default.createDirectory(at: bundle.transferDirectory, withIntermediateDirectories: true)
        dirs[transferShareName] = VZSharedDirectory(url: bundle.transferDirectory, readOnly: false)
        return VZMultipleDirectoryShare(directories: dirs)
    }

    static func directoryShares(config: VMConfig, bundle: VMBundle) throws -> [VZDirectorySharingDeviceConfiguration] {
        // Always attach the device (even with no shares) so folders can be added while running.
        let tag = config.guestOS == .macOS ? VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag : linuxShareTag
        let fs = VZVirtioFileSystemDeviceConfiguration(tag: tag)
        fs.share = directoryShare(config: config, bundle: bundle)
        var devices: [VZDirectorySharingDeviceConfiguration] = [fs]
        if config.guestOS == .linux && config.features.rosetta {
            switch VZLinuxRosettaDirectoryShare.availability {
            case .installed:
                let rosetta = VZVirtioFileSystemDeviceConfiguration(tag: rosettaTag)
                rosetta.share = try VZLinuxRosettaDirectoryShare()
                devices.append(rosetta)
            case .notInstalled:
                throw VitrineError.unsupported("Rosetta is not installed on this Mac — run `softwareupdate --install-rosetta`")
            default:
                throw VitrineError.unsupported("Rosetta for Linux is not available on this Mac")
            }
        }
        return devices
    }

    /// Whether this Mac can give a Linux guest hardware virtualization of its own (M3 or later, macOS 15+).
    public static var nestedVirtualizationSupported: Bool {
        if #available(macOS 15, *) { return VZGenericPlatformConfiguration.isNestedVirtualizationSupported }
        return false
    }

    static func linuxPlatform(bundle: VMBundle, nested: Bool = false) throws -> VZGenericPlatformConfiguration {
        let platform = VZGenericPlatformConfiguration()
        if nested {
            guard nestedVirtualizationSupported, #available(macOS 15, *) else {
                throw VitrineError.unsupported("nested virtualization needs an M3 or later Mac with macOS 15 or later; turn it off for this VM")
            }
            platform.isNestedVirtualizationEnabled = true
        }
        if let data = try? Data(contentsOf: bundle.machineIdentifierURL),
           let id = VZGenericMachineIdentifier(dataRepresentation: data) {
            platform.machineIdentifier = id
        } else {
            let id = VZGenericMachineIdentifier()
            try id.dataRepresentation.write(to: bundle.machineIdentifierURL)
            platform.machineIdentifier = id
        }
        return platform
    }

    static func linuxBootLoader(config: VMConfig, bundle: VMBundle) throws -> VZBootLoader {
        switch config.boot ?? .efi {
        case .efi:
            let loader = VZEFIBootLoader()
            if FileManager.default.fileExists(atPath: bundle.nvramURL.path) {
                loader.variableStore = VZEFIVariableStore(url: bundle.nvramURL)
            } else {
                loader.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: bundle.nvramURL)
            }
            return loader
        case .kernel(let kernel, let initrd, let commandLine):
            let image = try KernelImage.prepare(bundle.resolve(kernel), cacheDir: bundle.cacheDirectory)
            let loader = VZLinuxBootLoader(kernelURL: image)
            loader.initialRamdiskURL = initrd.map { bundle.resolve($0) }
            loader.commandLine = commandLine
            return loader
        }
    }

    /// The guest's serial console (hvc0): logged to console.log and reachable through
    /// `<socket dir>/serial.sock` (`vitrinectl console`) while the VM runs.
    static func serialConsole(bundle: VMBundle) throws -> VZSerialPortConfiguration {
        let bridge = try SerialConsoleBridge.start(bundle: bundle)
        let port = VZVirtioConsoleDeviceSerialPortConfiguration()
        port.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: bridge.toGuest.fileHandleForReading,
                                                           fileHandleForWriting: bridge.fromGuest.fileHandleForWriting)
        return port
    }

    /// Host caching and flush semantics for a disk. Linux guests get the host page cache even for
    /// `.automatic`: with the framework's own choice, Linux guests read whole 4 KiB pages of zeros
    /// for data that is intact on the disk image, which shows up as SIGILL, EIO and kernel oopses
    /// (docs/storage.md). UTM and Lima made the same switch.
    static func diskModes(_ caching: VMConfig.DiskConfig.Caching, guestOS: VMConfig.GuestOS)
        -> (VZDiskImageCachingMode, VZDiskImageSynchronizationMode) {
        switch caching {
        case .automatic: return (guestOS == .linux ? .cached : .automatic, .full)
        case .fast: return (.cached, .fsync)
        case .uncached: return (.uncached, .full)
        }
    }

    static func storageDevice(for disk: VMConfig.DiskConfig, guestOS: VMConfig.GuestOS,
                              bundle: VMBundle) throws -> VZStorageDeviceConfiguration {
        let url = bundle.resolve(disk.path)
        let (caching, sync) = diskModes(disk.caching, guestOS: guestOS)
        let attachment = try VZDiskImageStorageDeviceAttachment(url: url, readOnly: disk.readOnly,
                                                                cachingMode: caching, synchronizationMode: sync)
        switch disk.interface {
        case .virtio: return VZVirtioBlockDeviceConfiguration(attachment: attachment)
        case .nvme: return VZNVMExpressControllerDeviceConfiguration(attachment: attachment)
        case .usb: return VZUSBMassStorageDeviceConfiguration(attachment: attachment)
        }
    }

    static func macPlatform(bundle: VMBundle) throws -> VZMacPlatformConfiguration {
        let platform = VZMacPlatformConfiguration()
        guard let hwData = try? Data(contentsOf: bundle.hardwareModelURL),
              let hw = VZMacHardwareModel(dataRepresentation: hwData) else {
            throw VitrineError.fileNotFound("\(bundle.hardwareModelURL.path) (VM was never installed?)")
        }
        guard hw.isSupported else {
            throw VitrineError.unsupported("this VM's hardware model is not supported on this Mac")
        }
        platform.hardwareModel = hw
        platform.machineIdentifier = try machineIdentifier(bundle: bundle)
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.auxiliaryStorageURL)
        return platform
    }

    /// Loads the machine identifier, creating (and persisting) a new one for fresh clones.
    static func machineIdentifier(bundle: VMBundle) throws -> VZMacMachineIdentifier {
        if let data = try? Data(contentsOf: bundle.machineIdentifierURL),
           let id = VZMacMachineIdentifier(dataRepresentation: data) {
            return id
        }
        let id = VZMacMachineIdentifier()
        try id.dataRepresentation.write(to: bundle.machineIdentifierURL)
        return id
    }

    static func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }
}
