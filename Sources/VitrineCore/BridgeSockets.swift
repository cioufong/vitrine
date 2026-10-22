import Foundation

/// Where bridged networking is served from. Bridging a VM onto a Mac interface needs root, so a
/// privileged service owns the vmnet interfaces and hands VMs a Unix socket per Mac interface,
/// speaking QEMU's `-netdev stream` framing (4-byte big-endian length, then the Ethernet frame):
/// Vitrine's own helper (`vitrine-bridged`), or socket_vmnet set up for bridging.
public enum BridgeSockets {
    /// Vitrine's helper: `/var/run/vitrine/bridged.<interface>` (`VITRINE_BRIDGE_DIR` overrides it, for testing).
    public static var helperDirectory: String {
        ProcessInfo.processInfo.environment["VITRINE_BRIDGE_DIR"] ?? "/var/run/vitrine"
    }
    public static let helperLabel = "com.vitrine.bridged"

    public static func helperSocket(_ interface: String) -> String { "\(helperDirectory)/bridged.\(interface)" }

    /// socket_vmnet's bridged sockets: Homebrew (`brew services`) and the /opt/socket_vmnet install Lima documents.
    public static func socketVmnetCandidates(_ interface: String) -> [String] {
        ["/opt/homebrew/var/run/socket_vmnet.bridged.\(interface)",
         "/usr/local/var/run/socket_vmnet.bridged.\(interface)",
         "/var/run/socket_vmnet.bridged.\(interface)"]
    }

    public enum Provider: Equatable, Sendable { case vitrine, socketVmnet }

    /// A socket this user can connect to for bridging onto `interface`, preferring Vitrine's helper.
    public static func socket(for interface: String) -> (path: String, provider: Provider)? {
        guard !interface.isEmpty, !interface.contains("/") else { return nil }
        let own = helperSocket(interface)
        if isUsableSocket(own) { return (own, .vitrine) }
        if let path = socketVmnetCandidates(interface).first(where: isUsableSocket) { return (path, .socketVmnet) }
        return nil
    }

    /// Whether Vitrine's helper is installed (its directory exists), even if it serves no socket yet.
    public static var helperInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/\(helperLabel).plist")
    }

    static func isUsableSocket(_ path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0, st.st_mode & S_IFMT == S_IFSOCK else { return false }
        return access(path, R_OK | W_OK) == 0
    }
}
