import Foundation

/// Persistent description of a virtual machine. Stored as `config.json` inside a `.vitrinevm` bundle.
public struct VMConfig: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int = VMConfig.currentVersion
    public var id: UUID = UUID()
    public var name: String
    public var guestOS: GuestOS
    public var cpuCount: Int
    public var memoryMiB: UInt64
    public var disks: [DiskConfig] = []
    public var shares: [SharedDirectory] = []
    public var network: NetworkConfig = .init()
    public var display: DisplayConfig = .init()
    public var features: Features = .init()
    /// Guest account created on first boot. Its password lives in the bundle (guest-account.secret, 0600).
    public var account: GuestAccount?
    /// Installed OS, e.g. "macOS 27.0.1 (26A434)". Informational.
    public var installedOS: String?
    /// Linux boot method (ignored for macOS guests). nil means UEFI.
    public var boot: LinuxBoot?
    /// Installer ISO attached as a read-only USB drive (Linux). Removed after installation.
    public var installMedia: String?
    public var backend: Backend?
    public var architecture: Architecture?
    /// Additional read-only discs (QEMU), e.g. the Windows unattended-setup seed.
    public var extraMedia: [String]?
    public var notes: String = ""
    /// The system disk was enlarged; the guest's partition is extended once its agent connects.
    public var pendingDiskGrow: Bool?
    /// Unattended Windows setup can run without network: its seed carries everything (OpenSSH
    /// included). Set at creation; emulated x64 setup is then run offline (see QEMUMachine).
    public var windowsSetupOffline: Bool?
    /// The agent installed by Windows setup's first-logon script has connected: setup got that far,
    /// so the install media go at the next stop even if its own power-off didn't happen.
    public var windowsSetupAgentSeen: Bool?
    /// Host name the guest announces to DHCP (Linux guests set up by cloud-init). Kept when the VM
    /// is cloned or renamed: the disk still announces it, and DUID-based DHCP clients such as
    /// systemd-networkd record no MAC address, so the lease can only be found by this name.
    public var guestHostname: String?

    public init(name: String, guestOS: GuestOS = .macOS, cpuCount: Int = 4, memoryMiB: UInt64 = 8192) {
        self.name = name
        self.guestOS = guestOS
        self.cpuCount = cpuCount
        self.memoryMiB = memoryMiB
    }

    public enum GuestOS: String, Codable, Sendable, CaseIterable {
        case macOS, linux, windows
    }

    /// Execution engine. nil/`.vz` = Apple Virtualization.framework (fastest); `.qemu` = QEMU child
    /// process (Windows, x86_64 emulation, devices VZ lacks).
    public enum Backend: String, Codable, Sendable, CaseIterable { case vz, qemu }
    public enum Architecture: String, Codable, Sendable, CaseIterable { case aarch64, x86_64 }

    public var effectiveBackend: Backend { backend ?? .vz }
    public var effectiveArchitecture: Architecture { architecture ?? .aarch64 }

    public struct DiskConfig: Codable, Equatable, Sendable {
        public var path: String
        public var readOnly: Bool = false
        public var interface: Interface = .virtio
        public var caching: Caching = .automatic
        public enum Interface: String, Codable, Sendable { case virtio, nvme, usb }
        public enum Caching: String, Codable, Sendable {
            /// Full fsync semantics; host page cache for Linux guests, the framework's choice for macOS
            /// guests (docs/storage.md). Safe default.
            case automatic
            /// Host page cache, guest flushes are honored but not forced to stable storage. Fastest.
            case fast
            /// Bypass host cache.
            case uncached
        }
        public init(path: String, readOnly: Bool = false, interface: Interface = .virtio) {
            self.path = path; self.readOnly = readOnly; self.interface = interface
        }
    }

    public struct SharedDirectory: Codable, Equatable, Sendable, Identifiable {
        public var id: String { name }
        public var hostPath: String
        public var name: String
        public var readOnly: Bool = false
        /// Windows guests: the drive letter it is mapped to ("Z"), kept so that adding or removing
        /// another folder doesn't move it.
        public var driveLetter: String?
        public init(hostPath: String, name: String, readOnly: Bool = false) {
            self.hostPath = hostPath; self.name = name; self.readOnly = readOnly
        }

        /// SMB share names: ≤ 80 characters, no surrounding spaces, none of the characters Windows rejects.
        public static func isValidSMBName(_ name: String) -> Bool {
            !name.isEmpty && name.count <= 80 && name.trimmingCharacters(in: .whitespaces) == name
                && !name.contains { "\\/[]:|<>+=;,*?\"%".contains($0) || $0.isNewline || ($0.asciiValue ?? 32) < 32 }
        }

        /// 9p mount tag for QEMU Linux guests: letters, digits, '-' and '_', at most 31 bytes
        /// (virtio-9p's limit). `mount -t 9p -o trans=virtio <tag> /mnt/<tag>` in the guest.
        public var mountTag: String {
            let s = String(name.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "_" })
            return String(s.prefix(31))
        }

        /// Names Samba treats as configuration sections (or Vitrine uses itself): not for shared folders.
        public static func isReservedSMBName(_ name: String) -> Bool {
            ["global", "homes", "printers", "print$", "ipc$", "vitrinetransfer"].contains(name.lowercased())
        }
    }

    public struct NetworkConfig: Codable, Equatable, Sendable {
        public enum Mode: String, Codable, Sendable, CaseIterable {
            /// Internet through the Mac (NAT). VMs on Virtualization.framework also reach each other.
            case nat
            /// No internet: the guest reaches the Mac and other host-only VMs of the same Vitrine
            /// process (Virtualization.framework, macOS 26+), or only forwarded ports (QEMU).
            case hostOnly
            /// A named network from `VirtualNetworks` (`networkName`): its own subnet shared with the
            /// other VMs on it. macOS 26+.
            case network
            /// On the Mac's physical network (`bridgeInterface`), with an address from its router.
            /// Needs the Vitrine network helper or socket_vmnet.
            case bridged
            /// No network adapter.
            case none
        }
        public var mode: Mode = .nat
        /// `network` mode: the `VirtualNetwork` to join.
        public var networkName: String?
        /// `bridged` mode: BSD name of the Mac interface ("en0").
        public var bridgeInterface: String?
        /// `network` mode: an address reserved for this VM by the network's DHCP server.
        public var fixedIPv4: String?
        /// Stable MAC so DHCP leases (and therefore guest IP lookup) survive reboots.
        public var macAddress: String = randomMACAddress()
        /// Ports on the Mac forwarded into the guest.
        public var portForwards: [PortForward] = []
        public init() {}

        public var isConnected: Bool { mode != .none }

        /// QEMU guests on NAT and host-only use QEMU's user-mode network (slirp): forwarded ports,
        /// SSH and the Samba share ride on it. The other modes give the guest a real address.
        public var usesQEMUUserNetwork: Bool { mode == .nat || mode == .hostOnly }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mode = (try? c.decodeIfPresent(Mode.self, forKey: .mode)) ?? .nat
            networkName = try c.decodeIfPresent(String.self, forKey: .networkName)
            bridgeInterface = try c.decodeIfPresent(String.self, forKey: .bridgeInterface)
            fixedIPv4 = try c.decodeIfPresent(String.self, forKey: .fixedIPv4)
            macAddress = try c.decodeIfPresent(String.self, forKey: .macAddress) ?? randomMACAddress()
            portForwards = try c.decodeIfPresent([PortForward].self, forKey: .portForwards) ?? []
        }
    }

    /// A port on the Mac forwarded to a port in the guest.
    public struct PortForward: Codable, Equatable, Hashable, Sendable, Identifiable {
        public enum Proto: String, Codable, Sendable, CaseIterable { case tcp, udp }
        public var proto: Proto = .tcp
        /// Address on the Mac to listen on: 127.0.0.1 (this Mac only) or 0.0.0.0 (the local network).
        public var hostAddress: String = "127.0.0.1"
        public var hostPort: Int
        public var guestPort: Int
        public var id: String { "\(proto.rawValue):\(hostAddress):\(hostPort)" }

        public init(proto: Proto = .tcp, hostAddress: String = "127.0.0.1", hostPort: Int, guestPort: Int) {
            self.proto = proto; self.hostAddress = hostAddress; self.hostPort = hostPort; self.guestPort = guestPort
        }

        /// Parses `[udp:][ADDR:]HOSTPORT:GUESTPORT`, e.g. `8080:80`, `0.0.0.0:2222:22`, `udp:5353:53`.
        public init?(spec: String) {
            var parts = spec.split(separator: ":").map(String.init)
            var proto = Proto.tcp
            if let first = parts.first, let p = Proto(rawValue: first.lowercased()) { proto = p; parts.removeFirst() }
            guard parts.count == 2 || parts.count == 3, let guest = Int(parts[parts.count - 1]),
                  let host = Int(parts[parts.count - 2]) else { return nil }
            self.init(proto: proto, hostAddress: parts.count == 3 ? parts[0] : "127.0.0.1", hostPort: host, guestPort: guest)
        }

        public var spec: String {
            (proto == .udp ? "udp:" : "") + (hostAddress == "127.0.0.1" ? "" : hostAddress + ":") + "\(hostPort):\(guestPort)"
        }
    }

    public struct DisplayConfig: Codable, Equatable, Sendable {
        public var widthPixels: Int = 2560
        public var heightPixels: Int = 1600
        public var pixelsPerInch: Int = 220
        /// Resize the guest display when the window resizes (macOS 14+).
        public var autoResize: Bool = true
        public init() {}
        public init(widthPixels: Int, heightPixels: Int, pixelsPerInch: Int) {
            self.widthPixels = widthPixels; self.heightPixels = heightPixels; self.pixelsPerInch = pixelsPerInch
        }
    }

    public struct Features: Codable, Equatable, Sendable {
        /// Clipboard sharing (SPICE agent port + Vitrine agent).
        public var clipboard: Bool = true
        /// Seamless per-window integration through the Vitrine guest agent.
        public var coherence: Bool = true
        public var sound: Bool = true
        public var microphone: Bool = false
        /// What closing the VM window does while the VM runs.
        public var closeAction: CloseAction = .suspend
        /// Start the VM when Vitrine launches.
        public var startWithVitrine: Bool = false
        /// Rosetta for x86_64 Linux binaries (Linux guests; tag "rosetta").
        public var rosetta: Bool = false
        /// Set the guest's clock and time zone from the Mac whenever the agent connects.
        public var timeSync: Bool = true
        /// What happens when a USB device is plugged into the Mac while this VM is running.
        public var usbConnect: USBConnectPolicy = .ask
        /// Let a Linux guest run its own VMs (KVM). Virtualization.framework, M3 or later, macOS 15+.
        public var nestedVirtualization: Bool = false
        /// Discard everything a run changes (disks, NVRAM, TPM, settings) when the VM stops.
        public var disposable: Bool = false
        /// Swap ⌘ and ⌥ for the guest (Windows and Linux keep Alt where the Mac has ⌘).
        public var swapCommandOption: Bool = false
        /// Scale the guest display with nearest-neighbour sampling (crisp pixels; QEMU guests).
        public var pixelPerfectScaling: Bool = false
        /// QEMU's GDB remote stub on 127.0.0.1:<port> (kernel debugging); nil = off.
        public var gdbPort: Int?
        /// UEFI Secure Boot with Microsoft's keys enrolled (x86_64 guests on QEMU).
        public var secureBoot: Bool = false
        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            clipboard = try c.decodeIfPresent(Bool.self, forKey: .clipboard) ?? true
            coherence = try c.decodeIfPresent(Bool.self, forKey: .coherence) ?? true
            sound = try c.decodeIfPresent(Bool.self, forKey: .sound) ?? true
            microphone = try c.decodeIfPresent(Bool.self, forKey: .microphone) ?? false
            closeAction = try c.decodeIfPresent(CloseAction.self, forKey: .closeAction) ?? .suspend
            startWithVitrine = try c.decodeIfPresent(Bool.self, forKey: .startWithVitrine) ?? false
            rosetta = try c.decodeIfPresent(Bool.self, forKey: .rosetta) ?? false
            timeSync = try c.decodeIfPresent(Bool.self, forKey: .timeSync) ?? true
            usbConnect = (try? c.decodeIfPresent(USBConnectPolicy.self, forKey: .usbConnect)) ?? .ask
            nestedVirtualization = try c.decodeIfPresent(Bool.self, forKey: .nestedVirtualization) ?? false
            disposable = try c.decodeIfPresent(Bool.self, forKey: .disposable) ?? false
            swapCommandOption = try c.decodeIfPresent(Bool.self, forKey: .swapCommandOption) ?? false
            pixelPerfectScaling = try c.decodeIfPresent(Bool.self, forKey: .pixelPerfectScaling) ?? false
            gdbPort = try c.decodeIfPresent(Int.self, forKey: .gdbPort)
            secureBoot = try c.decodeIfPresent(Bool.self, forKey: .secureBoot) ?? false
        }
    }

    /// Choice for newly plugged-in USB devices.
    public enum USBConnectPolicy: String, Codable, Sendable, CaseIterable {
        /// Ask while the VM is in front (otherwise the device stays with the Mac).
        case ask
        /// Connect to this VM while it is in front (or the only running VM).
        case connect
        /// Leave new devices with the Mac; connect them from the Devices menu.
        case keepOnMac
    }

    public enum LinuxBoot: Codable, Equatable, Sendable {
        /// UEFI firmware with an NVRAM variable store in the bundle (boots ISOs and installed systems).
        case efi
        /// Direct kernel boot. Paths are absolute or bundle-relative; gzip/EFI-zboot kernels are unpacked.
        case kernel(kernel: String, initrd: String?, commandLine: String)
    }

    public enum CloseAction: String, Codable, Sendable, CaseIterable {
        case suspend, shutDown, keepRunning, ask
    }

    public struct GuestAccount: Codable, Equatable, Sendable {
        public var fullName: String
        public var username: String
        public var autoLogin: Bool = true
        public var remoteLogin: Bool = true
        /// Set once the first boot with provisioning options succeeded.
        public var provisioned: Bool = false
        /// Set once Vitrine installed the guest agent over SSH (nil = never attempted).
        public var agentInstalled: Bool?
        /// Set once Vitrine marked macOS setup complete (cold boots then skip Setup Assistant).
        public var setupFinalized: Bool?
        public init(fullName: String, username: String) {
            self.fullName = fullName; self.username = username
        }
    }
}

public extension VMConfig {
    /// Drive letters Windows shared folders take, from Z: down.
    static let shareDriveLetters = Array("ZYXWVUTSRQPONMLKJIHGFED").map(String.init)

    /// Gives every shared folder without a drive letter the first free one (Z: down), keeping the
    /// letters already chosen. Returns whether anything changed.
    @discardableResult
    mutating func assignDriveLetters() -> Bool {
        var used = Set<String>()
        var changed = false
        // A hand-edited config may hold an invalid or repeated letter: those are chosen again.
        for i in shares.indices {
            guard let letter = shares[i].driveLetter else { continue }
            if Self.shareDriveLetters.contains(letter), used.insert(letter).inserted { continue }
            shares[i].driveLetter = nil
            changed = true
        }
        for i in shares.indices where shares[i].driveLetter == nil {
            guard let free = Self.shareDriveLetters.first(where: { !used.contains($0) }) else { break }
            shares[i].driveLetter = free
            used.insert(free)
            changed = true
        }
        return changed
    }

    static let minimumMemoryMiB: UInt64 = 2048

    /// Checks invariants that don't depend on the backend runtime.
    func validate(bundle: VMBundle? = nil, hostCPUs: Int = ProcessInfo.processInfo.processorCount,
                  hostMemoryMiB: UInt64 = ProcessInfo.processInfo.physicalMemory / (1 << 20)) throws {
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            throw VitrineError.invalidConfig("VM name must not be empty")
        }
        if name.contains("/") || name.hasPrefix(".") {
            throw VitrineError.invalidConfig("VM name must not contain '/' or start with '.'")
        }
        if cpuCount < 1 { throw VitrineError.invalidConfig("cpuCount must be ≥ 1") }
        if cpuCount > hostCPUs {
            throw VitrineError.invalidConfig("cpuCount \(cpuCount) exceeds host CPUs (\(hostCPUs))")
        }
        if memoryMiB < VMConfig.minimumMemoryMiB {
            throw VitrineError.invalidConfig("memory must be at least \(VMConfig.minimumMemoryMiB) MiB")
        }
        if memoryMiB > hostMemoryMiB {
            throw VitrineError.invalidConfig("memory \(memoryMiB) MiB exceeds host memory (\(hostMemoryMiB) MiB)")
        }
        if disks.isEmpty { throw VitrineError.invalidConfig("at least one disk is required") }
        var shareNames = Set<String>()
        var mountTags = Set<String>()
        for share in shares {
            if share.name.isEmpty || share.name.contains("/") {
                throw VitrineError.invalidConfig("invalid share name '\(share.name)'")
            }
            // Windows shares are SMB shares (case-insensitive, stricter character set).
            if guestOS == .windows && !SharedDirectory.isValidSMBName(share.name) {
                throw VitrineError.invalidConfig("share name '\(share.name)' can't be used with Windows (avoid \\ / [ ] : | < > + = ; , * ? \" %)")
            }
            if guestOS == .windows && SharedDirectory.isReservedSMBName(share.name) {
                throw VitrineError.invalidConfig("the share name \(share.name) is reserved (Samba or Vitrine uses it)")
            }
            // Samba expands %-macros in share paths (no escape exists), trims surrounding spaces and
            // reads a trailing backslash as a line continuation.
            if guestOS == .windows && (share.hostPath.contains("%") || share.hostPath.hasSuffix("\\")
                                       || share.hostPath.trimmingCharacters(in: .whitespaces) != share.hostPath) {
                throw VitrineError.invalidConfig("Samba can't share this folder path with Windows (it contains \"%\", or ends in a space or backslash): \(share.hostPath)")
            }
            if !shareNames.insert(guestOS == .windows ? share.name.lowercased() : share.name).inserted {
                throw VitrineError.invalidConfig("duplicate share name \(share.name)")
            }
            if guestOS != .windows && effectiveBackend == .qemu {
                if !mountTags.insert(share.mountTag).inserted {
                    throw VitrineError.invalidConfig("shared folders \"\(share.name)\" and another one map to the same mount tag \(share.mountTag); rename one")
                }
                if share.hostPath.contains(",") {
                    throw VitrineError.invalidConfig("QEMU can't share a folder whose path contains a comma: \(share.hostPath)")
                }
            }
        }
        if display.widthPixels < 640 || display.heightPixels < 480 {
            throw VitrineError.invalidConfig("display must be at least 640×480")
        }
        if let account {
            if !account.username.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." })
                || account.username.isEmpty {
                throw VitrineError.invalidConfig("username may only contain letters, digits, '_', '-', '.'")
            }
        }
        if guestOS == .macOS && (boot != nil || features.rosetta) {
            throw VitrineError.invalidConfig("boot method and Rosetta only apply to Linux guests")
        }
        if guestOS == .macOS && effectiveBackend != .vz {
            throw VitrineError.invalidConfig("macOS guests require the Virtualization.framework backend")
        }
        if guestOS == .windows && effectiveBackend != .qemu {
            throw VitrineError.invalidConfig("Windows guests run on the QEMU backend")
        }
        if effectiveArchitecture == .x86_64 && effectiveBackend != .qemu {
            throw VitrineError.invalidConfig("x86_64 guests need the QEMU backend (emulation)")
        }
        if features.rosetta && effectiveBackend != .vz {
            throw VitrineError.invalidConfig("Rosetta for Linux is only available on the Virtualization.framework backend")
        }
        var forwarded = Set<String>()
        for f in network.portForwards {
            guard (1...65535).contains(f.hostPort), (1...65535).contains(f.guestPort) else {
                throw VitrineError.invalidConfig("port forward \(f.spec): ports must be between 1 and 65535")
            }
            guard ["127.0.0.1", "0.0.0.0", "::1", "::"].contains(f.hostAddress) || f.hostAddress.split(separator: ".").count == 4 else {
                throw VitrineError.invalidConfig("port forward \(f.spec): listen on an IPv4 address such as 127.0.0.1 or 0.0.0.0")
            }
            guard forwarded.insert("\(f.proto.rawValue):\(f.hostPort)").inserted else {
                throw VitrineError.invalidConfig("port \(f.hostPort)/\(f.proto.rawValue) is forwarded twice")
            }
        }
        switch network.mode {
        case .network where (network.networkName ?? "").isEmpty:
            throw VitrineError.invalidConfig("choose which network \(name) joins")
        case .bridged where (network.bridgeInterface ?? "").isEmpty:
            throw VitrineError.invalidConfig("choose the Mac interface to bridge \(name) to")
        default: break
        }
        if let ip = network.fixedIPv4, IPv4Subnet.parse(ip) == nil {
            throw VitrineError.invalidConfig("\(ip) is not an IPv4 address")
        }
        if !network.portForwards.isEmpty && !network.isConnected {
            throw VitrineError.invalidConfig("port forwards need a network adapter")
        }
        if features.secureBoot && (effectiveBackend != .qemu || effectiveArchitecture != .x86_64) {
            throw VitrineError.invalidConfig("Secure Boot with Microsoft keys is available for x86_64 guests on QEMU (QEMU's Arm firmware has no Secure Boot)")
        }
        if let port = features.gdbPort {
            guard effectiveBackend == .qemu else { throw VitrineError.invalidConfig("the GDB stub is only available on the QEMU backend") }
            guard (1024...65535).contains(port) else { throw VitrineError.invalidConfig("GDB port must be between 1024 and 65535") }
        }
        if features.nestedVirtualization && (guestOS != .linux || effectiveBackend != .vz) {
            throw VitrineError.invalidConfig("nested virtualization is only available for Linux guests on the Virtualization.framework backend")
        }
        if let bundle {
            if let media = installMedia, !FileManager.default.fileExists(atPath: bundle.resolve(media).path) {
                throw VitrineError.fileNotFound(bundle.resolve(media).path)
            }
            if case .kernel(let k, let i, _) = boot {
                for p in [k] + (i.map { [$0] } ?? []) where !FileManager.default.fileExists(atPath: bundle.resolve(p).path) {
                    throw VitrineError.fileNotFound(bundle.resolve(p).path)
                }
            }
            for disk in disks where !FileManager.default.fileExists(atPath: bundle.resolve(disk.path).path) {
                throw VitrineError.fileNotFound(bundle.resolve(disk.path).path)
            }
            for share in shares {
                var isDir: ObjCBool = false
                let path = bundle.resolve(share.hostPath).path
                if !FileManager.default.fileExists(atPath: path, isDirectory: &isDir) || !isDir.boolValue {
                    throw VitrineError.fileNotFound(path)
                }
            }
        }
    }
}

public enum VitrineError: Error, LocalizedError, Equatable {
    case invalidConfig(String)
    case fileNotFound(String)
    case unsupported(String)
    case backend(String)
    case io(String)
    case protocolError(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidConfig(let m): return "Invalid configuration: \(m)"
        case .fileNotFound(let p): return "File not found: \(p)"
        case .unsupported(let m): return "Unsupported: \(m)"
        case .backend(let m): return "Virtual machine error: \(m)"
        case .io(let m): return "I/O error: \(m)"
        case .protocolError(let m): return "Agent protocol error: \(m)"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Generates a locally administered unicast MAC address.
public func randomMACAddress() -> String {
    var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
    bytes[0] = (bytes[0] & 0xFE) | 0x02
    return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
}
