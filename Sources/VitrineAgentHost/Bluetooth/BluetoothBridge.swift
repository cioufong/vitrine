import CoreBluetooth
import Foundation

/// One guest's emulated Bluetooth controller, run on its own queue over the Mac's Bluetooth. HCI
/// packets from the guest go to `receive`; the controller's go out through `send`, on that queue.
public final class BluetoothBridge {
    private let queue = DispatchQueue(label: "vitrine.bluetooth")
    private var controller: BLEController?

    /// Whether the user has allowed (or not yet been asked to allow) Vitrine to use Bluetooth.
    public static var accessDenied: Bool {
        CBManager.authorization == .denied || CBManager.authorization == .restricted
    }

    /// `address` seeds the controller's own address (a VM's identifier, say), so each guest sees
    /// the same one every run.
    public init(seed: UUID, send: @escaping (Data) -> Void, unavailable: @escaping (String) -> Void) {
        let u = seed.uuid
        // Locally administered bits don't exist for public Bluetooth addresses; keep clear of the
        // all-zero and all-ones addresses the kernel treats specially.
        let address = [u.10, u.11, u.12, u.13, u.14, u.15 == 0xFF ? 0xFE : u.15 | 0x01]
        queue.sync {
            let radio = CoreBluetoothRadio(queue: queue)
            let c = BLEController(address: address, radio: radio, send: send)
            c.onUnavailable = unavailable
            controller = c
        }
    }

    public func receive(_ packet: Data) {
        queue.async { self.controller?.receive(packet) }
    }

    public func stop() {
        queue.sync {
            controller?.shutdown()
            controller = nil
        }
    }
}
