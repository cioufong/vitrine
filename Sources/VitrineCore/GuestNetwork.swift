import Foundation

/// Finds a NAT guest's IP address from macOS's bootpd lease database.
public enum GuestNetwork {
    public static let leasesPath = "/var/db/dhcpd_leases"

    /// Returns the most recent IPv4 address leased to `mac`.
    public static func ipAddress(forMAC mac: String, leases: String? = nil) -> String? {
        newestLease(leases) { hw, _ in hw.map(normalize) == normalize(mac) }?.ip
    }

    /// The newest lease whose (hardware address, host name) satisfies `matches`.
    static func newestLease(_ leases: String?, matching matches: (String?, String?) -> Bool) -> (ip: String, lease: UInt64)? {
        guard let text = leases ?? (try? String(contentsOfFile: leasesPath, encoding: .utf8)) else { return nil }
        var best: (ip: String, lease: UInt64)?
        for block in text.components(separatedBy: "}") {
            var ip: String?, hw: String?, name: String?, lease: UInt64 = 0
            for raw in block.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("ip_address=") { ip = String(line.dropFirst("ip_address=".count)) }
                if line.hasPrefix("name=") { name = String(line.dropFirst("name=".count)) }
                if line.hasPrefix("hw_address=") {
                    // Format: "1,a:b:c:d:e:f" — type prefix, octets without leading zeros.
                    let v = line.dropFirst("hw_address=".count)
                    hw = v.split(separator: ",", maxSplits: 1).last.map(String.init)
                }
                if line.hasPrefix("lease=") {
                    lease = UInt64(line.dropFirst("lease=".count).replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0
                }
            }
            if let ip, matches(hw, name), lease >= (best?.lease ?? 0) { best = (ip, lease) }
        }
        return best
    }

    /// Host name Vitrine assigns to Linux guests it provisions.
    public static func hostname(forVMName name: String) -> String {
        let s = String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return s.isEmpty ? "vitrine" : String(s.prefix(60))
    }

    /// Best-effort guest IP: DHCP lease by MAC, then the ARP cache.
    public static func resolve(mac: String, hostname: String?) -> String? {
        let candidates = self.candidates(mac: mac, hostname: hostname)
        if candidates.count <= 1 { return candidates.first }
        // Leases go stale when a guest switches DHCP client (e.g. after installing NetworkManager):
        // prefer the address that answers on SSH right now.
        return candidates.first { tcpReachable($0, port: 22, timeoutMs: 300) } ?? candidates.first
    }

    /// Addresses bound to the VM's MAC, without duplicates. A hostname alone is not an identity:
    /// clones can retain the source guest's hostname and SSH keys.
    public static func candidates(mac: String, hostname: String?, leases: String? = nil, arp: [String]? = nil) -> [String] {
        let byMAC = newestLease(leases) { hw, _ in hw.map(normalize) == normalize(mac) }
        var out: [String] = []
        for ip in [byMAC?.ip] + (arp ?? arpLookupAll(mac: mac)) {
            if let ip, !out.contains(ip) { out.append(ip) }
        }
        return out
    }

    /// TCP connect probe. Uses /usr/bin/nc: macOS's Local Network privacy blocks connections to the
    /// VM subnet from non-platform binaries ("No route to host") unless the user grants access, while
    /// Apple's own tools (nc, ssh) are exempt.
    public static func tcpReachable(_ host: String, port: UInt16, timeoutMs: Int32) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        p.arguments = ["-z", "-G", "\(max(1, (timeoutMs + 999) / 1000))", host, "\(port)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    static func arpLookupAll(mac: String) -> [String] {
        guard let first = arpLookup(mac: mac) else { return [] }
        var all = [first]
        if let text = arpTable() {
            let want = normalize(mac)
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: " ")
                guard let at = parts.firstIndex(of: "at"), at >= 1, at + 1 < parts.count,
                      normalize(String(parts[at + 1])) == want else { continue }
                let ip = parts[at - 1].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                if !all.contains(ip) { all.append(ip) }
            }
        }
        return all
    }

    static func arpTable() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        p.arguments = ["-an"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return text
    }

    public static func ipAddress(forHostname name: String, leases: String? = nil) -> String? {
        newestLease(leases) { _, n in n?.lowercased() == name.lowercased() }?.ip
    }

    /// Parses `arp -an` ("? (192.168.64.4) at be:47:a9:b7:36:2c on bridge100 …").
    public static func arpLookup(mac: String, arpOutput: String? = nil) -> String? {
        let text: String
        if let arpOutput { text = arpOutput } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
            p.arguments = ["-an"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
        }
        let want = normalize(mac)
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard let atIdx = parts.firstIndex(of: "at"), atIdx + 1 < parts.count, atIdx >= 1 else { continue }
            if normalize(String(parts[atIdx + 1])) == want {
                return parts[atIdx - 1].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            }
        }
        return nil
    }

    /// The hardware address the ARP cache has for `ip`; nil without a complete entry.
    public static func arpMAC(forIP ip: String, arpOutput: String? = nil) -> String? {
        guard let text = arpOutput ?? arpTable() else { return nil }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard let at = parts.firstIndex(of: "at"), at >= 1, at + 1 < parts.count,
                  parts[at - 1].trimmingCharacters(in: CharacterSet(charactersIn: "()")) == ip else { continue }
            let mac = String(parts[at + 1])
            return mac.split(separator: ":").count == 6 ? mac : nil  // "(incomplete)" says nothing
        }
        return nil
    }

    // MARK: Addresses seen on the wire

    /// The IPv4 address a frame the guest sent claims as its own: the sender of an ARP packet or
    /// the source of an IPv4 packet, when the frame comes from `mac` (bridges and containers
    /// inside the guest use other MACs). nil otherwise, and for the 0.0.0.0 of ARP probes and
    /// DHCP requests. Used where the Mac has no DHCP lease for the guest: macOS's Local Network
    /// privacy hides the ARP cache from non-Apple processes (sysctl returns nothing, and so does
    /// /usr/sbin/arp run by one). The bytes come from the guest; only the offsets read are checked.
    public static func senderIPv4(ofFrame frame: UnsafeRawBufferPointer, from mac: [UInt8]) -> UInt32? {
        guard mac.count == 6, frame.count >= 14, frame[6..<12].elementsEqual(mac) else { return nil }
        func be32(_ at: Int) -> UInt32 { (at..<at + 4).reduce(0) { $0 << 8 | UInt32(frame[$1]) } }
        let ip: UInt32
        switch UInt16(frame[12]) << 8 | UInt16(frame[13]) {
        case 0x0806:  // ARP for IPv4 over Ethernet: sender hardware address at 22, protocol address at 28
            guard frame.count >= 42, frame[14] == 0, frame[15] == 1, frame[16] == 0x08, frame[17] == 0,
                  frame[18] == 6, frame[19] == 4, frame[22..<28].elementsEqual(mac) else { return nil }
            ip = be32(28)
        case 0x0800:  // IPv4: source address at 12 of the header
            guard frame.count >= 34, frame[14] >> 4 == 4, frame[14] & 0x0f >= 5 else { return nil }
            ip = be32(26)
        default:
            return nil
        }
        return ip == 0 ? nil : ip
    }

    /// "d2:91:8d:80:1a:95" as bytes; nil unless it is six hex octets.
    public static func macBytes(_ mac: String) -> [UInt8]? {
        let octets = mac.split(separator: ":", omittingEmptySubsequences: false).map { UInt8($0, radix: 16) }
        guard octets.count == 6, octets.allSatisfy({ $0 != nil }) else { return nil }
        return octets.compactMap { $0 }
    }

    // MARK: Addresses reported by the guest

    /// Whether `ip`, an address the guest says it has, may be used to reach it. Nothing a guest
    /// can't own: unspecified (0/8), loopback, link-local, multicast, reserved or broadcast
    /// (224/3), or one of the Mac's own addresses (a forward would then reach a service on the
    /// Mac). With `ranges` (the VM network's assignable addresses, when known) it must be in one.
    public static func isPlausibleGuestAddress(_ ip: String, within ranges: [ClosedRange<UInt32>]?,
                                               hostAddresses: Set<UInt32>) -> Bool {
        guard let a = IPv4Subnet.parse(ip) else { return false }
        let first = a >> 24
        if first == 0 || first == 127 || first >= 224 || a >> 16 == (169 << 8 | 254) { return false }
        if hostAddresses.contains(a) { return false }
        return ranges.map { list in list.contains { $0.contains(a) } } ?? true
    }

    /// Whether `ip` may be `config`'s guest on the network its adapter is on now.
    public static func isPlausibleGuestAddress(_ ip: String, for config: VMConfig) -> Bool {
        let host = hostIPv4Addresses()
        return isPlausibleGuestAddress(ip, within: guestRanges(config, host: host), hostAddresses: Set(host.map(\.address)))
    }

    /// Assignable addresses of the network `config`'s adapter is on, when Vitrine knows them: a
    /// named network's configured subnet, or the subnets the Mac has on the bridged interface.
    /// NAT, host-only and named networks without a subnet get one macOS picks.
    public static func guestRanges(_ config: VMConfig, host: [HostAddress]) -> [ClosedRange<UInt32>]? {
        switch config.network.mode {
        case .network:
            return config.network.networkName.flatMap(VirtualNetworks.named)?.subnet
                .flatMap(IPv4Subnet.init(cidr:)).map { [$0.assignableRange] }
        case .bridged:
            let ranges = host.filter { $0.interface == config.network.bridgeInterface && $0.mask != 0 && ~$0.mask >= 3 }
                .map { ($0.address & $0.mask + 1)...($0.address | ~$0.mask) - 1 }
            return ranges.isEmpty ? nil : ranges
        case .nat, .hostOnly, .none:
            return nil
        }
    }

    public struct HostAddress: Equatable, Sendable {
        public let interface: String
        /// Host byte order.
        public let address: UInt32, mask: UInt32
    }

    /// The Mac's IPv4 addresses, with their interfaces and netmasks.
    public static func hostIPv4Addresses() -> [HostAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        // sin_addr is bytes 4..<8 of a sockaddr_in. Netmasks may come truncated to their nonzero
        // bytes (sa_len), so only read what is there.
        func ipv4(_ sa: UnsafeMutablePointer<sockaddr>) -> UInt32 {
            let len = Int(sa.pointee.sa_len), raw = UnsafeRawPointer(sa)
            return (4..<8).reduce(0) { v, i in v << 8 | (i < len ? UInt32(raw.load(fromByteOffset: i, as: UInt8.self)) : 0) }
        }
        var out: [HostAddress] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr, Int32(sa.pointee.sa_family) == AF_INET else { continue }
            out.append(HostAddress(interface: String(cString: p.pointee.ifa_name), address: ipv4(sa),
                                   mask: p.pointee.ifa_netmask.map(ipv4) ?? 0))
        }
        return out
    }

    static func normalize(_ mac: String) -> String {
        mac.lowercased().split(separator: ":").map { octet -> String in
            let trimmed = octet.drop { $0 == "0" }
            return trimmed.isEmpty ? "0" : String(trimmed)
        }.joined(separator: ":")
    }
}
