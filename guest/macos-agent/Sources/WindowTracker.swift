import AppKit
import CoreGraphics
import VitrineAgentProtocol

/// Enumerates on-screen guest windows (front-to-back) for Coherence.
enum WindowTracker {
    // CGWindowLevel values (see CGWindowLevel.h).
    static let dockLevel = Int(CGWindowLevelForKey(.dockWindow))           // 20
    static let mainMenuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))   // 24
    static let statusLevel = Int(CGWindowLevelForKey(.statusWindow))       // 25
    static let popUpMenuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow)) // 101
    static let screenSaverLevel = Int(CGWindowLevelForKey(.screenSaverWindow)) // 1000: cursor, screen savers, overlays above

    /// System chrome that Coherence never mirrors (the host provides its own). Matched by bundle ID
    /// because owner names are localized (e.g. 「通知中心」).
    static let excludedBundleIDs: Set<String> = [
        "com.apple.dock", "com.apple.WindowManager", "com.apple.wallpaper.agent", "com.apple.notificationcenterui",
        "com.apple.controlcenter", "com.apple.systemuiserver", "com.apple.loginwindow", "com.apple.TextInputMenuAgent",
    ]
    static let excludedOwners: Set<String> = ["Window Server"]

    static func snapshot(excludingPID ownPID: pid_t = getpid()) -> [WindowInfo] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var focusedAssigned = false
        var result: [WindowInfo] = []
        for w in raw {
            guard let id = w[kCGWindowNumber as String] as? UInt32,
                  let pid = w[kCGWindowOwnerPID as String] as? Int32,
                  let layer = w[kCGWindowLayer as String] as? Int,
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
            if pid == ownPID || alpha < 0.01 || bounds.width < 2 || bounds.height < 2 { continue }
            if excludedOwners.contains(owner) || layer == dockLevel || layer < 0 { continue }
            if let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, excludedBundleIDs.contains(bid) { continue }
            if layer >= screenSaverLevel { continue }
            let kind: WindowInfo.Kind
            switch layer {
            case 0: kind = .normal
            case mainMenuLevel, statusLevel: continue // guest menu bar & status items: host provides its own
            case popUpMenuLevel...: kind = .menu
            default: kind = .panel
            }
            let app = NSRunningApplication(processIdentifier: pid)
            var focused = false
            if !focusedAssigned, kind == .normal, pid == frontPID { focused = true; focusedAssigned = true }
            result.append(WindowInfo(
                id: id, pid: pid, appName: app?.localizedName ?? owner, bundleID: app?.bundleIdentifier,
                title: w[kCGWindowName as String] as? String ?? "",
                frame: Rect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height),
                layer: layer, kind: kind, isFocused: focused))
        }
        return result
    }

    static func displayInfo() -> DisplayInfo {
        let screen = NSScreen.screens.first ?? NSScreen.main!
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return DisplayInfo(widthPoints: screen.frame.width, heightPoints: screen.frame.height,
                           scale: screen.backingScaleFactor, menuBarHeight: max(menuBar, 0))
    }
}
