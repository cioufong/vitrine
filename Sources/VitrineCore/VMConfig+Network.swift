import Foundation

public extension VMConfig {
    /// Current guest IP (NAT), resolved from DHCP leases or the ARP cache.
    var guestIPAddress: String? {
        GuestNetwork.resolve(mac: network.macAddress, hostname: dhcpHostname)
    }

    /// The name to look the guest up by in DHCP leases (Linux guests).
    var dhcpHostname: String? {
        guard guestOS == .linux else { return nil }
        return guestHostname ?? GuestNetwork.hostname(forVMName: name)
    }
}

public extension VMBundle {
    /// The VM adapter's address as the process running the VM last learned it, from the guest's
    /// agent or from the frames it relays. Named, host-only and bridged networks hand out
    /// addresses the Mac's DHCP lease file doesn't know about.
    var reportedGuestIPURL: URL { socketDirectory.appendingPathComponent("guest-ip") }

    /// Called by the process running the VM; nil clears it.
    func recordGuestIP(_ ip: String?) {
        guard let ip else { try? FileManager.default.removeItem(at: reportedGuestIPURL); return }
        try? FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true)
        try? "\(getpid()) \(ip)\n".write(to: reportedGuestIPURL, atomically: true, encoding: .utf8)
    }

    /// The agent's report while the process that wrote it still runs the VM, if it is a plausible
    /// address for the VM (the guest is not trusted: forwards and SSH connect to it).
    func reportedGuestIP(_ config: VMConfig) -> String? {
        guard let text = try? String(contentsOf: reportedGuestIPURL, encoding: .utf8) else { return nil }
        let parts = text.split(whereSeparator: \.isWhitespace)
        guard parts.count == 2, let pid = pid_t(parts[0]), pid == runningPID() else { return nil }
        let ip = String(parts[1])
        guard GuestNetwork.isPlausibleGuestAddress(ip, for: config) else { return nil }
        // The Mac has seen another adapter use that address: it is some other machine's (another VM's).
        if let owner = GuestNetwork.arpMAC(forIP: ip),
           GuestNetwork.normalize(owner) != GuestNetwork.normalize(config.network.macAddress) { return nil }
        return ip
    }

    /// Best guest IP for `config`: the fixed address on a named network (the host assigned it),
    /// the agent's report, then DHCP leases and the ARP cache.
    func guestIPAddress(_ config: VMConfig) -> String? {
        if config.network.mode == .network, let fixed = config.network.fixedIPv4 { return fixed }
        if let ip = reportedGuestIP(config) { return ip }
        switch config.network.mode {
        case .network:
            return GuestNetwork.arpLookupAll(mac: config.network.macAddress).first
        case .bridged, .hostOnly:
            // Not in the Mac's DHCP leases; an old NAT lease for this MAC would be on the wrong network.
            return GuestNetwork.arpLookupAll(mac: config.network.macAddress).first
        case .nat, .none:
            return config.guestIPAddress
        }
    }
}
