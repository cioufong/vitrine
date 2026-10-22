import Foundation

/// A named virtual network that VMs can join: they reach each other and the Mac on its own subnet,
/// and (shared) the internet through the Mac. Kept in `networks.json` in the VM library.
public struct VirtualNetwork: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// NAT to the internet through the Mac.
        case shared
        /// The Mac and the other VMs on the network only.
        case hostOnly
    }
    public var name: String
    public var kind: Kind
    /// IPv4 subnet in CIDR form ("192.168.100.0/24"). nil lets macOS pick a free /24.
    public var subnet: String?
    /// Hand out addresses with DHCP. Off: guests configure static addresses themselves.
    public var dhcp: Bool
    public var id: String { name }

    public init(name: String, kind: Kind = .shared, subnet: String? = nil, dhcp: Bool = true) {
        self.name = name; self.kind = kind; self.subnet = subnet; self.dhcp = dhcp
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .shared
        subnet = try c.decodeIfPresent(String.self, forKey: .subnet)
        dhcp = try c.decodeIfPresent(Bool.self, forKey: .dhcp) ?? true
    }

    /// Letters, digits, spaces, "-" and "_", up to 32 characters.
    public static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed == name && name.count <= 32
            && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || " -_".unicodeScalars.contains($0) }
    }

    /// Why this definition can't be used, or nil.
    public var problem: String? {
        if !Self.isValidName(name) { return "network names use letters, digits, spaces, - and _ (up to 32)" }
        if let subnet, IPv4Subnet(cidr: subnet) == nil {
            return "\(subnet) is not a private IPv4 subnet between /16 and /29 (e.g. 192.168.100.0/24)"
        }
        return nil
    }
}

/// An IPv4 subnet in a private range (10/8, 172.16/12, 192.168/16), /16…/29.
public struct IPv4Subnet: Equatable, Hashable, Sendable {
    /// Network address, host byte order.
    public let network: UInt32
    public let prefix: Int

    public init?(cidr: String) {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]), (16...29).contains(prefix),
              let address = IPv4Subnet.parse(String(parts[0])) else { return nil }
        let mask = UInt32.max << UInt32(32 - prefix)
        let network = address & mask
        let isPrivate = network >> 24 == 10 || network >> 20 == (172 << 4 | 1) || network >> 16 == (192 << 8 | 168)
        guard isPrivate else { return nil }
        self.network = network; self.prefix = prefix
    }

    public var mask: UInt32 { UInt32.max << UInt32(32 - prefix) }
    public var cidr: String { "\(Self.format(network))/\(prefix)" }
    /// The Mac's address on the network (vmnet reserves the second address for the host).
    public var hostAddress: String { Self.format(network + 1) }
    /// Addresses guests may use: everything but the network, host and broadcast addresses.
    public var assignableRange: ClosedRange<UInt32> { (network + 2)...(network | ~mask) - 1 }

    public func contains(_ address: String) -> Bool {
        guard let a = Self.parse(address) else { return false }
        return a & mask == network
    }

    public static func parse(_ s: String) -> UInt32? {
        let octets = s.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var v: UInt32 = 0
        for o in octets {
            guard !o.isEmpty, o.count <= 3, o.allSatisfy(\.isNumber), let n = UInt32(o), n <= 255 else { return nil }
            v = v << 8 | n
        }
        return v
    }

    public static func format(_ v: UInt32) -> String {
        "\(v >> 24 & 255).\(v >> 16 & 255).\(v >> 8 & 255).\(v & 255)"
    }
}

/// The library's named networks (`networks.json` next to the VMs).
public enum VirtualNetworks {
    public static var url: URL { VMLibrary.root.appendingPathComponent("networks.json") }

    public static func load() -> [VirtualNetwork] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([VirtualNetwork].self, from: data) else { return [] }
        return list
    }

    public static func named(_ name: String) -> VirtualNetwork? { load().first { $0.name == name } }

    public static func save(_ networks: [VirtualNetwork]) throws {
        if let bad = networks.first(where: { $0.problem != nil }) {
            throw VitrineError.invalidConfig("\(bad.name): \(bad.problem!)")
        }
        var seen = Set<String>()
        for n in networks where !seen.insert(n.name.lowercased()).inserted {
            throw VitrineError.invalidConfig("there are two networks named \(n.name)")
        }
        let subnets = networks.compactMap { $0.subnet.flatMap(IPv4Subnet.init(cidr:)) }
        for (i, a) in subnets.enumerated() {
            for b in subnets[(i + 1)...] where a.network & b.mask == b.network || b.network & a.mask == a.network {
                throw VitrineError.invalidConfig("subnets \(a.cidr) and \(b.cidr) overlap")
            }
        }
        try FileManager.default.createDirectory(at: VMLibrary.root, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(networks).write(to: url, options: .atomic)
    }
}
