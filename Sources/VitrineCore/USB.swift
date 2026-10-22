import Foundation
import IOKit

/// A USB device plugged into the Mac.
public struct HostUSBDevice: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var vendorID: UInt16
    public var productID: UInt16
    /// IOKit location ID: bus number in the top byte, then the port path.
    public var locationID: UInt32
    /// Bus address (libusb's device address on macOS).
    public var address: UInt8
    public var registryID: UInt64
    public var name: String?
    public var vendor: String?
    public var serial: String?
    /// A USB hub (never offered to VMs automatically).
    public var isHub: Bool?
    /// Has a mass-storage interface (a drive the guest may be writing to).
    public var isStorage: Bool?

    public init(vendorID: UInt16, productID: UInt16, locationID: UInt32, address: UInt8, registryID: UInt64,
                name: String? = nil, vendor: String? = nil, serial: String? = nil, isHub: Bool? = nil,
                isStorage: Bool? = nil) {
        self.vendorID = vendorID; self.productID = productID; self.locationID = locationID
        self.address = address; self.registryID = registryID
        self.name = name; self.vendor = vendor; self.serial = serial; self.isHub = isHub; self.isStorage = isStorage
    }

    /// Stable within one plug-in: "vvvv:pppp@locationID".
    public var id: String { String(format: "%04x:%04x@%08x", vendorID, productID, locationID) }
    /// libusb's bus number on macOS.
    public var busNumber: Int { Int(locationID >> 24) }
    public var displayName: String {
        let n = [vendor, name].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return n.isEmpty ? String(format: "USB device %04x:%04x", vendorID, productID) : n.joined(separator: " ")
    }

    /// Matches "vvvv:pppp" (any instance) or a full id "vvvv:pppp@location".
    public func matches(_ spec: String) -> Bool {
        let s = spec.lowercased()
        return s == id || s == String(format: "%04x:%04x", vendorID, productID)
    }
}

public enum HostUSB {
    /// USB devices currently attached to the Mac (internal hubs and the like included).
    public static func devices() -> [HostUSBDevice] {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return [] }
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var out: [HostUSBDevice] = []
        while case let service = IOIteratorNext(it), service != 0 {
            defer { IOObjectRelease(service) }
            if let d = device(service) { out.append(d) }
        }
        return out.sorted { $0.locationID < $1.locationID }
    }

    static func device(_ service: io_service_t) -> HostUSBDevice? {
        func prop(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        guard let vid = (prop("idVendor") as? NSNumber)?.uint16Value,
              let pid = (prop("idProduct") as? NSNumber)?.uint16Value else { return nil }
        var rid: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &rid)
        return HostUSBDevice(
            vendorID: vid, productID: pid,
            locationID: (prop("locationID") as? NSNumber)?.uint32Value ?? 0,
            address: (prop("USB Address") as? NSNumber)?.uint8Value ?? 0,
            registryID: rid,
            name: prop("USB Product Name") as? String ?? prop("kUSBProductString") as? String,
            vendor: prop("USB Vendor Name") as? String ?? prop("kUSBVendorString") as? String,
            serial: prop("USB Serial Number") as? String ?? prop("kUSBSerialNumberString") as? String,
            isHub: (prop("bDeviceClass") as? NSNumber)?.intValue == 9,
            isStorage: hasInterface(service, ofClass: 8))
    }

    /// Whether one of the device's interfaces has USB class `cls` (8 = mass storage).
    static func hasInterface(_ service: io_service_t, ofClass cls: Int) -> Bool {
        var it: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &it) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(it) }
        while case let child = IOIteratorNext(it), child != 0 {
            defer { IOObjectRelease(child) }
            let value = IORegistryEntryCreateCFProperty(child, "bInterfaceClass" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber
            if value?.intValue == cls { return true }
        }
        return false
    }

    /// The plugged-in device that is `device` now (its address and registry entry change when it is
    /// re-plugged): same vendor/product and, when known, serial number; otherwise the same port.
    public static func current(matching device: HostUSBDevice, in list: [HostUSBDevice] = devices()) -> HostUSBDevice? {
        let same = list.filter { $0.vendorID == device.vendorID && $0.productID == device.productID }
        if let serial = device.serial, !serial.isEmpty {
            return same.first { $0.serial == serial }
        }
        return same.first { $0.locationID == device.locationID }
    }
}

/// Something plugged into a running VM's USB controller.
public enum USBAttachment: Codable, Equatable, Hashable, Sendable {
    /// A disk image (.img/.dmg/.iso/.raw) presented as a USB flash drive.
    case image(path: String, readOnly: Bool)
    /// A device plugged into the Mac, passed through.
    case host(HostUSBDevice)

    public var label: String {
        switch self {
        case .image(let path, let ro): return (path as NSString).lastPathComponent + (ro ? " (read-only)" : "")
        case .host(let d): return d.displayName
        }
    }
}

/// An attachment with the id it was given in the VM ("usb1", "usb2", …).
public struct AttachedUSB: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var attachment: USBAttachment
    public init(id: String, attachment: USBAttachment) { self.id = id; self.attachment = attachment }
}
