import Darwin
import Foundation
import VitrineAgentProtocol

/// The guest's Ethernet interfaces and addresses, for hosts that can't find the guest in the Mac's
/// DHCP leases (vmnet and bridged networks).
enum NetworkReporter {
    static func snapshot() -> GuestNetworkInfo {
        var macs: [String: String] = [:]
        var v4: [String: [String]] = [:]
        var v6: [String: [String]] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return GuestNetworkInfo(interfaces: []) }
        defer { freeifaddrs(head) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            switch Int32(addr.pointee.sa_family) {
            case AF_LINK:
                // The name and address follow each other from sdl_data on and may run past its
                // declared 12 bytes ("bridge0" + a MAC needs 13): read the sockaddr itself, up to sdl_len.
                let mac = addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl -> String? in
                    let start = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)! + Int(dl.pointee.sdl_nlen)
                    guard dl.pointee.sdl_alen == 6, start + 6 <= Int(dl.pointee.sdl_len) else { return nil }
                    let raw = UnsafeRawPointer(dl)
                    return (0..<6).map { String(format: "%02x", raw.load(fromByteOffset: start + $0, as: UInt8.self)) }
                        .joined(separator: ":")
                }
                if let mac { macs[name] = mac }
            case AF_INET, AF_INET6:
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let len = socklen_t(addr.pointee.sa_family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
                guard getnameinfo(addr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
                let s = String(cString: host)
                if addr.pointee.sa_family == AF_INET { v4[name, default: []].append(s) } else if !s.hasPrefix("fe80") {
                    v6[name, default: []].append(s)
                }
            default: break
            }
        }
        let interfaces = macs.keys.sorted().compactMap { name -> GuestNetworkInfo.Interface? in
            guard let mac = macs[name], v4[name] != nil || v6[name] != nil else { return nil }
            return .init(name: name, mac: mac, ipv4: v4[name] ?? [], ipv6: v6[name] ?? [])
        }
        return GuestNetworkInfo(interfaces: Array(interfaces.prefix(16)))
    }
}
