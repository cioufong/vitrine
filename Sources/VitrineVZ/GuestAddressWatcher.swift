import Foundation
import VitrineCore

/// Learns the guest's IPv4 address from the frames it sends, on links whose frames pass through
/// Vitrine (bridged through a helper socket, QEMU on vmnet). The Mac has no DHCP lease for those
/// guests and macOS hides the ARP cache from Vitrine, so without an agent this is the only way to
/// find them; it also works before the Mac has talked to the guest.
///
/// The guest is not trusted: an address is used only if `accept` allows it, and while the current
/// one is still in use another (a second address, or a spoofed source) doesn't replace it.
final class GuestAddressWatcher: @unchecked Sendable {
    private let mac: [UInt8]
    private let accept: (String) -> Bool
    private let record: (String) -> Void
    private let lock = NSLock()
    private var current: UInt32?
    private var currentSeen: UInt64 = 0
    private var rejected: Set<UInt32> = []
    private var rejectedSince: UInt64 = 0

    /// How long the current address must go unused before another one replaces it.
    static let holdNanos: UInt64 = 30_000_000_000

    /// nil when `mac` isn't a MAC address.
    init?(mac: String, accept: @escaping (String) -> Bool, record: @escaping (String) -> Void) {
        guard let bytes = GuestNetwork.macBytes(mac) else { return nil }
        self.mac = bytes
        self.accept = accept
        self.record = record
    }

    /// The address learned so far.
    var address: String? {
        lock.lock(); defer { lock.unlock() }
        return current.map(IPv4Subnet.format)
    }

    /// Called for every frame the guest sends.
    func observe(_ frame: UnsafeRawBufferPointer, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        guard let ip = GuestNetwork.senderIPv4(ofFrame: frame, from: mac) else { return }
        lock.lock()
        if ip == current {
            currentSeen = now
            lock.unlock()
            return
        }
        if current != nil, now &- currentSeen < Self.holdNanos {
            lock.unlock()
            return
        }
        // Checking reads the Mac's addresses; remember refusals for a while (the Mac's own
        // addresses can change, so not forever), and don't let a guest grow the set without bound.
        if now &- rejectedSince > Self.holdNanos || rejected.count >= 64 {
            rejected.removeAll()
            rejectedSince = now
        }
        guard !rejected.contains(ip) else { lock.unlock(); return }
        let text = IPv4Subnet.format(ip)
        guard accept(text) else {
            rejected.insert(ip)
            lock.unlock()
            return
        }
        current = ip
        currentSeen = now
        lock.unlock()
        record(text)
    }
}
