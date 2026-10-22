import Foundation
import Security

/// Restricted entitlements a Vitrine build may be signed with. Ad-hoc builds (the default) have
/// none of them; a build signed with your own Apple Developer team and a provisioning profile that
/// grants them turns the matching features on (docs/signing.md).
public enum Entitlement: String, CaseIterable, Sendable {
    /// Bridged networking without the root helper (VZBridgedNetworkDeviceAttachment, vmnet bridged mode).
    case vmNetworking = "com.apple.vm.networking"
    /// Passing Mac USB devices to Virtualization.framework VMs (macOS 27, AccessoryAccess).
    case usbAccessory = "com.apple.developer.accessory-access.usb"

    /// Whether this process is signed with it.
    public var isGranted: Bool { Self.granted.contains(self) }

    private static let granted: Set<Entitlement> = {
        guard let task = SecTaskCreateFromSelf(nil) else { return [] }
        return Set(allCases.filter { (SecTaskCopyValueForEntitlement(task, $0.rawValue as CFString, nil) as? Bool) == true })
    }()
}
