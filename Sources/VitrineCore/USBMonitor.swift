import Foundation
import IOKit

/// Reports USB devices plugged into or removed from the Mac (on the main run loop). Devices
/// present when monitoring starts are not reported.
public final class HostUSBMonitor {
    public var onArrival: ((HostUSBDevice) -> Void)?
    /// The registry entry ID of a device that went away.
    public var onRemoval: ((UInt64) -> Void)?

    private var port: IONotificationPortRef?
    private var added: io_iterator_t = 0
    private var removed: io_iterator_t = 0

    public init() {}

    deinit { stop() }

    public func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("IOUSBHostDevice"), { ctx, it in
            guard let ctx else { return }
            Unmanaged<HostUSBMonitor>.fromOpaque(ctx).takeUnretainedValue().drain(it, arrived: true)
        }, me, &added)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching("IOUSBHostDevice"), { ctx, it in
            guard let ctx else { return }
            Unmanaged<HostUSBMonitor>.fromOpaque(ctx).takeUnretainedValue().drain(it, arrived: false)
        }, me, &removed)
        // Arm both notifications; what is already plugged in is not news.
        drain(added, arrived: nil)
        drain(removed, arrived: nil)
    }

    public func stop() {
        if added != 0 { IOObjectRelease(added); added = 0 }
        if removed != 0 { IOObjectRelease(removed); removed = 0 }
        if let port { IONotificationPortDestroy(port) }
        port = nil
    }

    /// `arrived` nil: just empty the iterator.
    private func drain(_ iterator: io_iterator_t, arrived: Bool?) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            switch arrived {
            case true?:
                if let d = HostUSB.device(service) { onArrival?(d) }
            case false?:
                var rid: UInt64 = 0
                IORegistryEntryGetRegistryEntryID(service, &rid)
                onRemoval?(rid)
            case nil:
                break
            }
        }
    }
}
