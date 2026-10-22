import Foundation
import vmnet
import VitrineCore

/// The vmnet networks (macOS 26) VMs join: the default host-only network and the named networks
/// from `VirtualNetworks`.
///
/// A vmnet network only lives as long as the process that created it, and VMs run from the app and
/// from separate `vitrinectl run` processes must share it. So each network is owned by a small
/// `vitrinectl netd <key>` process (unprivileged): it creates the network, publishes its
/// serialization, and exits a few seconds after the last process using it has gone. VM processes
/// join from the serialization and register their PID while they use it.
///
/// A network's settings apply when its owner starts: edits made while VMs use it take effect once
/// they have all stopped.
public enum VmnetNetworks {
    public struct Lease: Hashable, Sendable {
        let key: String
        fileprivate let token = UUID()
    }

    private struct Entry { let network: vmnet_network_ref; var users: Set<UUID> }
    nonisolated(unsafe) private static var entries: [String: Entry] = [:]
    private static let lock = NSLock()

    /// Where owners publish networks and clients register: per-user, outside the VM library.
    static var directory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vitrine-networks", isDirectory: true)
    }

    static func key(for config: VMConfig) throws -> String {
        switch config.network.mode {
        case .hostOnly:
            return "host-only"
        case .network:
            guard let name = config.network.networkName, !name.isEmpty else {
                throw VitrineError.invalidConfig("choose a network for \(config.name) (Configuration › Hardware › Network)")
            }
            guard VirtualNetworks.named(name) != nil else {
                throw VitrineError.invalidConfig("there is no network named “\(name)” (Settings › Networks)")
            }
            return "net:" + name
        default:
            throw VitrineError.invalidConfig("\(config.network.mode.rawValue) is not a vmnet network")
        }
    }

    /// The definition behind `key`, read fresh from the library.
    static func definition(forKey key: String) -> VirtualNetwork? {
        if key == "host-only" { return VirtualNetwork(name: key, kind: .hostOnly) }
        guard key.hasPrefix("net:") else { return nil }
        return VirtualNetworks.named(String(key.dropFirst(4)))
    }

    /// The network for `config` (host-only or named), joined from its owner. Pair with `release`.
    @available(macOS 26, *)
    static func acquire(for config: VMConfig) throws -> (network: vmnet_network_ref, lease: Lease) {
        let key = try key(for: config)
        lock.lock(); defer { lock.unlock() }
        let lease = Lease(key: key)
        if var entry = entries[key] {
            entry.users.insert(lease.token)
            entries[key] = entry
            return (entry.network, lease)
        }
        let network = try NetworkOwner.join(key: key)
        entries[key] = Entry(network: network, users: [lease.token])
        return (network, lease)
    }

    static func release(_ lease: Lease) {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[lease.key] else { return }
        entry.users.remove(lease.token)
        if entry.users.isEmpty {
            entries[lease.key] = nil
            NetworkOwner.unregister(key: lease.key)
        } else {
            entries[lease.key] = entry
        }
    }

    /// The subnet a running network got (macOS picks one when the definition has none), e.g.
    /// "192.168.65.0/24", or nil when no VM uses it.
    public static func activeSubnet(networkName name: String) -> String? {
        NetworkOwner.liveRecord(key: "net:" + name)?.subnet
    }

    /// `vitrinectl netd <key>`: the owner process of one network.
    @available(macOS 26, *)
    public static func serve(key: String) -> Never { NetworkOwner.serve(key: key) }

    @available(macOS 26, *)
    static func create(_ def: VirtualNetwork) throws -> vmnet_network_ref {
        var status = vmnet_return_t.VMNET_SUCCESS
        guard let cfg = vmnet_network_configuration_create(def.kind == .shared ? .VMNET_SHARED_MODE : .VMNET_HOST_MODE, &status) else {
            throw VitrineError.backend("could not configure network “\(def.name)” (vmnet status \(status.rawValue))")
        }
        if let cidr = def.subnet, let subnet = IPv4Subnet(cidr: cidr) {
            // vmnet takes the Mac's (gateway) address here, not the network address: x.x.x.0 fails
            // to start interfaces with EADDRNOTAVAIL.
            var addr = in_addr(s_addr: (subnet.network + 1).bigEndian)
            var mask = in_addr(s_addr: subnet.mask.bigEndian)
            let r = vmnet_network_configuration_set_ipv4_subnet(cfg, &addr, &mask)
            guard r == .VMNET_SUCCESS else {
                throw VitrineError.invalidConfig("network “\(def.name)”: macOS rejected subnet \(cidr) (vmnet status \(r.rawValue))")
            }
            if def.dhcp {
                for (mac, ip) in reservations(for: def.name, in: subnet) {
                    var ether = mac
                    var a = in_addr(s_addr: ip.bigEndian)
                    _ = vmnet_network_configuration_add_dhcp_reservation(cfg, &ether, &a)
                }
            }
        }
        if !def.dhcp { vmnet_network_configuration_disable_dhcp(cfg) }
        guard let network = vmnet_network_create(cfg, &status) else {
            throw VitrineError.backend("could not create network “\(def.name)” (vmnet status \(status.rawValue))")
        }
        return network
    }

    /// Fixed addresses of the library's VMs on network `name`.
    private static func reservations(for name: String, in subnet: IPv4Subnet) -> [(ether_addr_t, UInt32)] {
        VMLibrary.list().compactMap { bundle -> (ether_addr_t, UInt32)? in
            guard let c = try? bundle.loadConfig(), c.network.mode == .network, c.network.networkName == name,
                  let fixed = c.network.fixedIPv4, subnet.contains(fixed), let ip = IPv4Subnet.parse(fixed),
                  subnet.assignableRange.contains(ip), let mac = etherAddress(c.network.macAddress) else { return nil }
            return (mac, ip)
        }
    }

    static func etherAddress(_ mac: String) -> ether_addr_t? {
        let octets = mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard octets.count == 6 else { return nil }
        return ether_addr_t(octet: (octets[0], octets[1], octets[2], octets[3], octets[4], octets[5]))
    }
}
