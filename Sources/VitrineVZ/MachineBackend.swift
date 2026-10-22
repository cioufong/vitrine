import Foundation
import Virtualization
import VitrineCore
import VitrineAgentHost
import VitrineAgentProtocol
import VitrineQEMU

/// What VirtualMachineController does the same way on both backends once a machine is running:
/// a `VZBackend` or a `QEMUMachine`. Starting, suspending and force-stopping differ and stay in the
/// controller.
@MainActor
protocol MachineBackend: AnyObject {
    /// Asks the guest to shut down. False when the request couldn't be made (nothing to wait for).
    func requestStop() async -> Bool
    var hasStopped: Bool { get }
    func pause() async throws
    func resume() async throws
    /// Plugs the network cable in or pulls it. False when the machine has no adapter to do it on.
    func setNetworkCable(connected: Bool) async throws -> Bool
    func connectAgent() async -> AgentChannel?
    /// Returns a warning the backend reported (host devices on QEMU).
    func attachUSB(_ attachment: USBAttachment, id: String) async throws -> String?
    func detachUSB(_ attachment: USBAttachment, id: String) async throws
    func updateShares(_ config: VMConfig) throws
}

extension QEMUMachine: MachineBackend {
    func requestStop() async -> Bool {
        await requestShutdown()
        return true
    }

    var hasStopped: Bool { !isRunning }

    func setNetworkCable(connected: Bool) async throws -> Bool {
        try await setLink(up: connected)
        return true
    }
}

/// A Virtualization.framework machine and the runtime state the controller keeps for it.
@MainActor
final class VZBackend: MachineBackend {
    let vm: VZVirtualMachine
    let bundle: VMBundle
    /// Whether the configuration really has an xHCI controller (see VMBundle.savedStateUSBMarkerURL).
    let hasUSBController: Bool
    /// The attachment taken off the adapter while the cable is unplugged.
    private var unpluggedAttachment: VZNetworkDeviceAttachment?
    /// VZ device objects by attachment id.
    private var usbDevices: [String: AnyObject] = [:]

    init(vm: VZVirtualMachine, bundle: VMBundle, hasUSBController: Bool) {
        self.vm = vm
        self.bundle = bundle
        self.hasUSBController = hasUSBController
    }

    func requestStop() async -> Bool {
        vm.state == .running && vm.canRequestStop && (try? vm.requestStop()) != nil
    }

    var hasStopped: Bool { vm.state == .stopped }

    func pause() async throws { try await vm.pause() }
    func resume() async throws { try await vm.resume() }

    func setNetworkCable(connected: Bool) async throws -> Bool {
        guard let device = vm.networkDevices.first else { return false }
        if connected {
            if let a = unpluggedAttachment { device.attachment = a }
            unpluggedAttachment = nil
        } else if let a = device.attachment {
            unpluggedAttachment = a
            device.attachment = nil
        }
        return true
    }

    func connectAgent() async -> AgentChannel? {
        guard let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else { return nil }
        return await withCheckedContinuation { cont in
            socketDevice.connect(toPort: AgentProtocol.vsockPort) { result in
                switch result {
                case .success(let conn):
                    // Duplicate the descriptor: VZVirtioSocketConnection closes its own on dealloc.
                    let fd = dup(conn.fileDescriptor)
                    conn.close()
                    cont.resume(returning: fd >= 0 ? AgentChannel(fileDescriptor: fd) : nil)
                case .failure:
                    cont.resume(returning: nil)
                }
            }
        }
    }

    func attachUSB(_ attachment: USBAttachment, id: String) async throws -> String? {
        guard #available(macOS 15, *), let controller = vm.usbControllers.first else {
            throw VitrineError.unsupported(hasUSBController
                ? "USB needs macOS 15 or later"
                : "this session was resumed from a state saved without a USB controller; shut the VM down and start it again to use USB")
        }
        switch attachment {
        case .image(let path, let readOnly):
            if DiskImage.isUDIF(URL(fileURLWithPath: path)) {
                throw VitrineError.unsupported("Virtualization.framework attaches raw images only; convert the .dmg first: hdiutil convert \"\((path as NSString).lastPathComponent)\" -format UDTO -o image")
            }
            let disk = try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: path), readOnly: readOnly)
            let device = VZUSBMassStorageDevice(configuration: VZUSBMassStorageDeviceConfiguration(attachment: disk))
            try await controller.attach(device: device)
            usbDevices[id] = device
        case .host(let d):
            usbDevices[id] = try await VZUSBPassthrough.attach(d, to: controller)
        }
        return nil
    }

    func detachUSB(_ attachment: USBAttachment, id: String) async throws {
        if #available(macOS 15, *), let controller = vm.usbControllers.first, let device = usbDevices[id] as? VZUSBDevice {
            do {
                try await controller.detach(device: device)
            } catch let error as VZError where error.code == .deviceNotFound {
                // Already gone: VZ detaches a passthrough device by itself when it leaves the Mac.
            }
            VZUSBPassthrough.didDetach(device)
        }
        usbDevices[id] = nil
    }

    /// The virtiofs share is hot-swappable.
    func updateShares(_ config: VMConfig) throws {
        guard let device = vm.directorySharingDevices.first as? VZVirtioFileSystemDevice else { return }
        device.share = ConfigurationBuilder.directoryShare(config: config, bundle: bundle)
    }
}
