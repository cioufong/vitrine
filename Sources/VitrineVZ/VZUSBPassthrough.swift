import Foundation
import Security
import Virtualization
import VitrineCore
#if canImport(AccessoryAccess)
import AccessoryAccess
#endif

/// Passing Mac USB devices through to Virtualization.framework VMs (macOS 27+).
///
/// VZUSBPassthroughDevice wraps an AccessoryAccess `AAUSBAccessory`, and AccessoryAccess only talks
/// to apps signed with the `com.apple.developer.accessory-access.usb` entitlement ("Claim USB
/// Accessory" capability), which needs a provisioning profile from an Apple Developer team: ad-hoc
/// signed builds are killed at launch when they claim it. Without it this reports how to get it.
enum VZUSBPassthrough {
    static let entitlement = Entitlement.usbAccessory.rawValue

    static var hasEntitlement: Bool { Entitlement.usbAccessory.isGranted }

    @available(macOS 15, *)
    static func attach(_ device: HostUSBDevice, to controller: VZUSBController) async throws -> AnyObject {
        #if canImport(AccessoryAccess)
        if #available(macOS 27, *) {
            guard hasEntitlement else {
                throw VitrineError.unsupported("""
                    Passing USB devices to macOS and Linux VMs needs a Vitrine build signed with Apple's \
                    "Claim USB Accessory" capability (\(entitlement)); see docs/signing.md to sign it with \
                    your own team. USB drive images work without it; QEMU VMs can pass devices through.
                    """)
            }
            let accessory = try await AccessoryRegistry.shared.accessory(registryID: device.registryID)
            let passthrough = try VZUSBPassthroughDevice(configuration: VZUSBPassthroughDeviceConfiguration(device: accessory))
            try await controller.attach(device: passthrough)
            return passthrough
        }
        #endif
        throw VitrineError.unsupported("passing USB devices to macOS and Linux VMs needs macOS 27")
    }

    static func didDetach(_ device: AnyObject) {}
}

#if canImport(AccessoryAccess)
/// Tracks the USB accessories AccessoryAccess offers this app (it asks the user which ones).
@available(macOS 27, *)
final class AccessoryRegistry: NSObject, AAUSBAccessoryListener, @unchecked Sendable {
    static let shared = AccessoryRegistry()
    private let lock = NSLock()
    private var accessories: [UInt64: AAUSBAccessory] = [:]
    private var registered = false

    func accessory(registryID: UInt64) async throws -> AAUSBAccessory {
        try await register()
        guard let a = lock.withLock({ accessories[registryID] }) else {
            throw VitrineError.invalidConfig("macOS hasn't given Vitrine access to this USB device (allow it when asked, then try again)")
        }
        return a
    }

    private func register() async throws {
        if lock.withLock({ registered }) { return }
        let found: [AAUSBAccessory] = try await withCheckedThrowingContinuation { cont in
            AAUSBAccessoryManager.shared.registerListener(self, matchingCriteria: []) { list, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: list) }
            }
        }
        lock.withLock {
            registered = true
            for a in found { accessories[a.registryID] = a }
        }
    }

    func usbAccessoryDidConnect(_ usbAccessory: AAUSBAccessory) {
        lock.withLock { accessories[usbAccessory.registryID] = usbAccessory }
    }

    func usbAccessoryDidDisconnect(_ usbAccessory: AAUSBAccessory) {
        lock.withLock { accessories[usbAccessory.registryID] = nil }
    }
}
#endif
