import AppKit
import VitrineAgentProtocol

/// Installed apps, their icons and launching them, for the host's Dock icons and app launchers.
enum AppCatalogProvider {
    /// Folders scanned for .app bundles (one level deep, plus /Applications/Utilities).
    static let roots = ["/Applications", "/Applications/Utilities", "/System/Applications",
                        "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]

    static func catalog(iconSize: Int) -> AppCatalog {
        var seen = Set<String>()
        var apps: [AppCatalog.App] = []
        for root in roots {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for item in items.sorted() where item.hasSuffix(".app") {
                let path = (root as NSString).appendingPathComponent(item)
                guard let bundle = Bundle(path: path), let bid = bundle.bundleIdentifier,
                      seen.insert(bid).inserted, !isBackgroundOnly(bundle) else { continue }
                let name = FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
                apps.append(.init(id: path, name: name, key: bid,
                                  png: iconSize > 0 ? png(NSWorkspace.shared.icon(forFile: path), size: iconSize) : nil))
            }
        }
        return AppCatalog(apps: apps)
    }

    /// Icon for a window's app key (a bundle identifier, or a process name for odd apps).
    static func icon(forKey key: String, size: Int = 256) -> AppIcon {
        var image: NSImage?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == key }) {
            image = app.icon
        }
        return AppIcon(key: key, png: image.flatMap { png($0, size: size) } ?? Data())
    }

    /// Opens an app from the catalog (a path inside one of `roots`), or activates it if running.
    static func launch(_ id: String, log: @escaping (String) -> Void) {
        let url = URL(fileURLWithPath: id).standardizedFileURL
        guard url.pathExtension == "app",
              roots.contains(where: { url.deletingLastPathComponent().path == URL(fileURLWithPath: $0).standardizedFileURL.path }) else {
            log("launch refused: \(id) is not in an Applications folder")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error { DispatchQueue.main.async { log("launch \(url.lastPathComponent) failed: \(error.localizedDescription)") } }
        }
    }

    private static func isBackgroundOnly(_ bundle: Bundle) -> Bool {
        let info = bundle.infoDictionary ?? [:]
        return (info["LSUIElement"] as? Bool) == true || (info["LSBackgroundOnly"] as? Bool) == true
            || (info["LSUIElement"] as? String) == "1"
    }

    static func png(_ image: NSImage, size: Int) -> Data? {
        let s = NSSize(width: size, height: size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = s
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: s))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
