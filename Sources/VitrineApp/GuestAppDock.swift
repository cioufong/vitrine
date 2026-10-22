import AppKit
import VitrineCore
import VitrineAgentHost
import VitrineAgentProtocol

/// Writes the small app bundles that stand in for guest apps (see `GuestAppProxy`).
enum ProxyBundle {
    /// The Vitrine a proxy talks to (builds can be signed under another bundle ID).
    static var hostBundleID: String { Bundle.main.bundleIdentifier ?? GuestAppProxy.defaultHostBundleID }

    /// Creates or refreshes a proxy app at `url` (a ".app" path).
    static func write(at url: URL, name: String, bundleID: String, vmPath: String, key: String?, launchID: String?,
                      iconPNG: Data?) throws {
        // The proxy executable shipped inside Vitrine.app (or next to the binary in a dev build).
        guard let helper = BuildLayout.executable(named: "VitrineAppProxy") else { throw VitrineError.io("VitrineAppProxy is missing from this build") }
        let fm = FileManager.default
        let contents = url.appendingPathComponent("Contents")
        try? fm.removeItem(at: url)
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try DiskImage.clone(helper, to: contents.appendingPathComponent("MacOS/VitrineAppProxy"))
        var info: [String: Any] = [
            "CFBundleIdentifier": bundleID, "CFBundleName": name, "CFBundleDisplayName": name,
            "CFBundleExecutable": "VitrineAppProxy", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1", "LSMinimumSystemVersion": "14.0",
            "NSHighResolutionCapable": true, "NSPrincipalClass": "NSApplication",
            GuestAppProxy.InfoKey.vmPath: vmPath,
            GuestAppProxy.InfoKey.hostBundleID: hostBundleID,
        ]
        if let key { info[GuestAppProxy.InfoKey.appKey] = key }
        if let launchID { info[GuestAppProxy.InfoKey.launchID] = launchID }
        if let png = iconPNG, !png.isEmpty, let icns = ICNS.make(png: png) {
            try png.write(to: contents.appendingPathComponent("Resources/AppIcon.png"))
            try icns.write(to: contents.appendingPathComponent("Resources/AppIcon.icns"))
            info["CFBundleIconFile"] = "AppIcon"
        }
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        try sign(url)
    }

    /// Ad-hoc signs the bundle (the copied helper's signature doesn't cover the new Info.plist).
    private static func sign(_ url: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--force", "--sign", "-", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw VitrineError.io("codesign failed for \(url.lastPathComponent)") }
    }

    /// File-system-safe app name.
    static func safeName(_ name: String) -> String {
        // Guest text: no path separators, control characters or leading dots (hidden files).
        let cleaned = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "App" : String(cleaned.prefix(80))
    }
}

/// Minimal .icns writer: one PNG-encoded image of a standard size.
enum ICNS {
    static func make(png: Data) -> Data? {
        var data = png
        var size = pngSize(png)
        let types: [Int: String] = [128: "ic07", 256: "ic08", 512: "ic09", 1024: "ic10"]
        if size == nil || types[size!] == nil {
            guard let image = NSImage(data: png), let resized = render(image, size: 256) else { return nil }
            data = resized
            size = 256
        }
        guard let size, let type = types[size] else { return nil }
        var out = Data("icns".utf8)
        out.appendBigEndian(UInt32(8 + 8 + data.count))
        out.append(Data(type.utf8))
        out.appendBigEndian(UInt32(8 + data.count))
        out.append(data)
        return out
    }

    /// Width of a square PNG (from IHDR), nil otherwise.
    static func pngSize(_ png: Data) -> Int? {
        guard png.count > 24, png.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { return nil }
        let b = [UInt8](png[png.startIndex + 16 ..< png.startIndex + 24])
        let w = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
        let h = Int(b[4]) << 24 | Int(b[5]) << 16 | Int(b[6]) << 8 | Int(b[7])
        return w == h ? w : nil
    }

    static func render(_ image: NSImage, size: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

private extension Data {
    mutating func appendBigEndian(_ v: UInt32) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }
}

/// Dock icons for guest apps in Coherence, and launchers in ~/Applications/Vitrine Apps.
@MainActor
final class GuestAppDock {
    static let shared = GuestAppDock()

    /// Running Dock proxies: vm path → app key → process, and the name each was created with.
    private var running: [String: [String: NSRunningApplication]] = [:]
    private var runningNames: [String: [String: String]] = [:]
    /// Apps waiting for their icon before the proxy starts: vm path → key → name.
    private var waitingForIcon: [String: [String: String]] = [:]
    /// Apps that should have a Dock icon right now (vm path → key → name); a proxy that finishes
    /// launching after its app went away is quit again.
    private var wanted: [String: [String: String]] = [:]
    /// Proxies being written or launched: vm path → keys.
    private var launching: [String: Set<String>] = [:]

    /// Icons larger than this are ignored (the guest is not trusted to keep them small).
    nonisolated static let maxIconBytes = 4 << 20
    /// At most this many launchers per VM (each one is a signed app bundle).
    nonisolated static let maxLaunchers = 2000

    nonisolated static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Vitrine/AppProxies", isDirectory: true)
    nonisolated static let launchersRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications/Vitrine Apps", isDirectory: true)

    nonisolated static func vmID(_ bundle: VMBundle) -> String { GuestAppProxy.stableHash(bundle.url.path) }

    private func iconURL(_ bundle: VMBundle, key: String) -> URL {
        Self.root.appendingPathComponent(Self.vmID(bundle)).appendingPathComponent("icons/\(GuestAppProxy.stableHash(key)).png")
    }

    private func proxyURL(_ bundle: VMBundle, key: String, name: String) -> URL {
        Self.root.appendingPathComponent(Self.vmID(bundle))
            .appendingPathComponent(GuestAppProxy.stableHash(key))
            .appendingPathComponent(ProxyBundle.safeName(name) + ".app")
    }

    /// Reconciles Dock icons with the apps that have windows in Coherence.
    func update(_ bundle: VMBundle, session: AgentSession, apps: [CoherenceController.GuestApp]) {
        let vm = bundle.url.path
        let wanted = Dictionary(apps.map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })
        self.wanted[vm] = wanted
        waitingForIcon[vm] = waitingForIcon[vm]?.filter { wanted[$0.key] != nil }
        // Gone, quit, or renamed (the guest may learn an app's display name a moment later).
        for (key, app) in running[vm] ?? [:]
        where wanted[key] == nil || app.isTerminated || wanted[key] != runningNames[vm]?[key] {
            if !app.isTerminated { sendQuit(vm: vm, key: key) }
            running[vm]?[key] = nil
            runningNames[vm]?[key] = nil
        }
        for (key, name) in wanted where running[vm]?[key] == nil && launching[vm]?.contains(key) != true {
            if FileManager.default.fileExists(atPath: iconURL(bundle, key: key).path)
                || session.guestHello?.capabilities.contains("apps") != true {
                launchProxy(bundle, key: key, name: name)
            } else if waitingForIcon[vm]?[key] == nil {
                waitingForIcon[vm, default: [:]][key] = name
                session.send(.appIconRequest(AppIconRequest(key: key)))
                // Don't wait forever for a guest that never answers.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, let name = self.waitingForIcon[vm]?.removeValue(forKey: key) else { return }
                    self.launchProxy(bundle, key: key, name: name)
                }
            }
        }
    }

    /// An icon arrived from the guest: cache it and show the Dock icon that was waiting for it.
    /// Only icons this side asked for are taken, and only reasonably sized ones.
    func receivedIcon(_ bundle: VMBundle, _ icon: AppIcon) {
        guard let name = waitingForIcon[bundle.url.path]?.removeValue(forKey: icon.key) else { return }
        if !icon.png.isEmpty, icon.png.count <= Self.maxIconBytes, ICNS.pngSize(icon.png) != nil || NSImage(data: icon.png) != nil {
            let url = iconURL(bundle, key: icon.key)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? icon.png.write(to: url)
        }
        launchProxy(bundle, key: icon.key, name: name)
    }

    private func launchProxy(_ bundle: VMBundle, key: String, name: String) {
        let vm = bundle.url.path
        guard running[vm]?[key] == nil, launching[vm]?.contains(key) != true else { return }
        launching[vm, default: []].insert(key)
        let url = proxyURL(bundle, key: key, name: name)
        let iconFile = iconURL(bundle, key: key)
        let bundleID = "io.github.cioufong.vitrine.guestapp.\(Self.vmID(bundle)).\(GuestAppProxy.stableHash(key))"
        Task {
            // Writing and code-signing a bundle takes a while: keep it off the main thread.
            let written = await Task.detached { () -> Error? in
                let icon = try? Data(contentsOf: iconFile)
                guard !FileManager.default.fileExists(atPath: url.path) || Self.isStale(url, icon: icon) else { return nil }
                do {
                    try ProxyBundle.write(at: url, name: name, bundleID: bundleID, vmPath: vm, key: key, launchID: nil, iconPNG: icon)
                    return nil
                } catch { return error }
            }.value
            if let written {
                launching[vm]?.remove(key)
                NSLog("Vitrine: Dock icon for \(name) unavailable: \(written.localizedDescription)")
                return
            }
            guard wanted[vm]?[key] == name else { // gone or renamed meanwhile
                launching[vm]?.remove(key)
                if let current = wanted[vm]?[key] { launchProxy(bundle, key: key, name: current) }
                return
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.addsToRecentItems = false
            config.arguments = [GuestAppProxy.dockArgument]
            config.createsNewApplicationInstance = false
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
                Task { @MainActor in
                    self.launching[vm]?.remove(key)
                    if let app {
                        if self.wanted[vm]?[key] == name {
                            self.running[vm, default: [:]][key] = app
                            self.runningNames[vm, default: [:]][key] = name
                        } else {
                            self.sendQuit(vm: vm, key: key) // the app (or Coherence) went away while it launched
                            // Renamed meanwhile: start the proxy under its current name.
                            if let current = self.wanted[vm]?[key] { self.launchProxy(bundle, key: key, name: current) }
                        }
                    }
                    if let error { NSLog("Vitrine: could not start Dock proxy for \(name): \(error.localizedDescription)") }
                }
            }
        }
    }

    /// A proxy written for another Vitrine (a build with a different bundle ID, or one from before
    /// proxies recorded it), or before its icon was known.
    nonisolated private static func isStale(_ url: URL, icon: Data?) -> Bool {
        let info = (try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        guard info?[GuestAppProxy.InfoKey.hostBundleID] as? String == ProxyBundle.hostBundleID else { return true }
        guard let icon, !icon.isEmpty else { return false }
        return !FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Resources/AppIcon.png").path)
    }

    /// Removes every Dock icon of a VM (Coherence ended).
    func removeAll(_ bundle: VMBundle) {
        let vm = bundle.url.path
        for key in (running[vm] ?? [:]).keys { sendQuit(vm: vm, key: key) }
        running[vm] = nil
        runningNames[vm] = nil
        waitingForIcon[vm] = nil
        wanted[vm] = nil
    }

    private func sendQuit(vm: String, key: String) {
        DistributedNotificationCenter.default().postNotificationName(
            GuestAppProxy.controlNotification, object: nil,
            userInfo: ["vm": vm, "key": key, "command": GuestAppProxy.Command.quit.rawValue], deliverImmediately: true)
    }

    // MARK: Launchers

    /// Marks a launcher folder as belonging to one VM (its bundle path), so exporting another VM
    /// with a similar name never replaces it.
    nonisolated static let ownerMarker = ".vitrine-vm"

    /// ~/Applications/Vitrine Apps/<VM>, or "<VM> 2"… when that name is taken by another VM's folder
    /// (or `reserved` for another VM's export in progress).
    nonisolated static func launchersFolder(_ bundle: VMBundle, reserved: Set<String> = []) -> URL {
        let base = ProxyBundle.safeName(bundle.name)
        var n = 1
        while true {
            let folder = launchersRoot.appendingPathComponent(n == 1 ? base : "\(base) \(n)", isDirectory: true)
            // Names compare case-insensitively, as on the (default) case-insensitive APFS volume.
            if !reserved.contains(folder.path.lowercased()), isLaunchersFolder(folder, of: bundle) { return folder }
            n += 1
        }
    }

    /// Free, or this VM's: by its owner marker or — for folders exported before markers existed —
    /// because it holds launchers and nothing else, all pointing at this VM. Anything unexpected
    /// (other files, an unreadable folder) means it isn't ours to replace.
    nonisolated static func isLaunchersFolder(_ folder: URL, of bundle: VMBundle) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return true }
        if let owner = try? String(contentsOf: folder.appendingPathComponent(ownerMarker), encoding: .utf8) {
            return owner == bundle.url.path
        }
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return false }
        let entries = items.filter { $0.lastPathComponent != ".DS_Store" }
        return !entries.isEmpty && entries.allSatisfy { $0.pathExtension == "app" && launcherVMPath($0) == bundle.url.path }
    }

    nonisolated static func launcherVMPath(_ app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return info[GuestAppProxy.InfoKey.vmPath] as? String
    }

    /// Launcher folders being written, by the VM they're for (exports run concurrently off-main).
    private static var exporting: [String: String] = [:] // lowercased folder path → vm path

    /// Writes one launcher per guest app into ~/Applications/Vitrine Apps/<VM>, replacing old ones
    /// (off the main thread: each launcher is code-signed).
    /// Returns the folder and how many launchers it holds (the catalog is filtered and capped).
    func writeLaunchers(_ bundle: VMBundle, catalog: AppCatalog) async throws -> (folder: URL, count: Int) {
        guard !Self.exporting.values.contains(bundle.url.path) else {
            throw VitrineError.invalidConfig("launchers for \(bundle.name) are already being created")
        }
        let target = Self.launchersFolder(bundle, reserved: Set(Self.exporting.keys))
        let key = target.path.lowercased()
        Self.exporting[key] = bundle.url.path
        defer { Self.exporting[key] = nil }
        // The catalog comes from the guest: bounded, named sensibly, no oversized icons (an
        // oversized icon is dropped — the launcher gets the generic one — not the app).
        let apps = catalog.apps
            .filter { !$0.name.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "."))).isEmpty }
            .prefix(Self.maxLaunchers)
            .map { app -> AppCatalog.App in
                var app = app
                if (app.png?.count ?? 0) > Self.maxIconBytes { app.png = nil }
                return app
            }
        let folder = try await Task.detached { () throws -> URL in
            let fm = FileManager.default
            let folder = target
            let staging = folder.deletingLastPathComponent()
                .appendingPathComponent(".\(folder.lastPathComponent).\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            do {
                try bundle.url.path.write(to: staging.appendingPathComponent(Self.ownerMarker), atomically: true, encoding: .utf8)
                var used = Set<String>()
                for app in apps {
                    var name = ProxyBundle.safeName(app.name)
                    var n = 2
                    while !used.insert(name.lowercased()).inserted { name = "\(ProxyBundle.safeName(app.name)) \(n)"; n += 1 }
                    try ProxyBundle.write(at: staging.appendingPathComponent(name + ".app"), name: app.name,
                                          bundleID: "io.github.cioufong.vitrine.launcher.\(Self.vmID(bundle)).\(GuestAppProxy.stableHash(app.id))",
                                          vmPath: bundle.url.path, key: nil, launchID: app.id, iconPNG: app.png)
                }
                // Swap the finished folder in; the old one (ours, per launchersFolder) goes away —
                // checked again, since someone may have created or filled it meanwhile.
                guard Self.isLaunchersFolder(folder, of: bundle) else {
                    throw VitrineError.invalidConfig("\(folder.path) now holds other files; launchers not replaced")
                }
                if fm.fileExists(atPath: folder.path) {
                    _ = try fm.replaceItemAt(folder, withItemAt: staging)
                } else {
                    try fm.moveItem(at: staging, to: folder)
                }
            } catch {
                try? fm.removeItem(at: staging)
                throw error
            }
            return folder
        }.value
        Self.saveLaunchIDs(bundle, Set(apps.map(\.id)))
        return (folder, apps.count)
    }

    // MARK: Launch IDs

    /// IDs a launcher (or vitrine:// link) may ask to open: the apps exported for that VM. Anything
    /// else is refused, so other local processes and web pages can't run arbitrary guest commands.
    private static func launchIDsURL(_ bundle: VMBundle) -> URL {
        root.appendingPathComponent(vmID(bundle)).appendingPathComponent("launch-ids.json")
    }

    nonisolated static func saveLaunchIDs(_ bundle: VMBundle, _ ids: Set<String>) {
        let url = root.appendingPathComponent(vmID(bundle)).appendingPathComponent("launch-ids.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(ids.sorted()).write(to: url, options: .atomic)
    }

    static func isExportedLaunchID(_ bundle: VMBundle, _ id: String) -> Bool {
        if let data = try? Data(contentsOf: launchIDsURL(bundle)),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            return ids.contains(id)
        }
        // Launchers exported before the list existed: collect their IDs once (only launchers that
        // belong to this VM).
        let folder = launchersFolder(bundle)
        let apps = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let ids = Set(apps.filter { launcherVMPath($0) == bundle.url.path }.compactMap {
            Bundle(url: $0)?.object(forInfoDictionaryKey: GuestAppProxy.InfoKey.launchID) as? String
        })
        if !ids.isEmpty { saveLaunchIDs(bundle, ids) }
        return ids.contains(id)
    }
}
