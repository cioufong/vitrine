import Foundation

/// Contract between Vitrine and the small proxy apps that stand in for guest apps on the Mac: Dock
/// icons while a guest app has windows in Coherence, and launchers in ~/Applications/Vitrine Apps.
///
/// Each proxy is an app bundle whose Info.plist names the VM and the guest app. Proxies and Vitrine
/// talk through distributed notifications (same user, no sandbox).
public enum GuestAppProxy {
    /// Info.plist keys of a proxy bundle.
    public enum InfoKey {
        public static let vmPath = "VitrineVMPath"
        /// `WindowInfo.appKey` of the guest app (Dock proxies; launchers when the guest knows it).
        public static let appKey = "VitrineAppKey"
        /// `AppCatalog.App.id` (launchers).
        public static let launchID = "VitrineLaunchID"
        /// Vitrine's own bundle identifier (builds signed with your own team may change it).
        public static let hostBundleID = "VitrineHostBundleID"
    }

    /// The bundle identifier of Vitrine's official builds.
    public static let defaultHostBundleID = "io.github.cioufong.vitrine.app"

    /// Argument Vitrine passes when it starts a proxy only to show a Dock icon.
    public static let dockArgument = "--vitrine-dock"

    /// Proxy → Vitrine. userInfo: vm, key?, id?, event.
    public static let eventNotification = Notification.Name("io.github.cioufong.vitrine.guestapp.event")
    /// Vitrine → proxy. userInfo: vm, key, command.
    public static let controlNotification = Notification.Name("io.github.cioufong.vitrine.guestapp.control")

    public enum Event: String, Sendable {
        /// User opened a launcher: start the app in the guest.
        case launch
        /// User clicked the Dock icon: bring the app's windows forward.
        case activate
        /// User chose Quit on the Dock icon: close the app in the guest.
        case quit
    }

    public enum Command: String, Sendable {
        /// The guest app has no windows left (or Coherence ended): leave the Dock.
        case quit
    }

    /// URL Vitrine handles when a launcher finds it not running: vitrine://launch?vm=<path>&id=<id>.
    public static let urlScheme = "vitrine"

    public static func launchURL(vmPath: String, id: String) -> URL? {
        var c = URLComponents()
        c.scheme = urlScheme
        c.host = "launch"
        c.queryItems = [URLQueryItem(name: "vm", value: vmPath), URLQueryItem(name: "id", value: id)]
        return c.url
    }

    public static func parseLaunchURL(_ url: URL) -> (vmPath: String, id: String)? {
        guard url.scheme == urlScheme, url.host == "launch",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let vm = items.first(where: { $0.name == "vm" })?.value,
              let id = items.first(where: { $0.name == "id" })?.value else { return nil }
        return (vm, id)
    }

    /// A short stable hash for file and bundle names (FNV-1a, hex).
    public static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}
