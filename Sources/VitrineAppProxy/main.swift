import AppKit
import VitrineCore

// Stand-in for a guest app on the Mac: shows its icon in the Dock while it has Coherence windows
// (started by Vitrine with --vitrine-dock), or launches it from ~/Applications/Vitrine Apps.

final class ProxyDelegate: NSObject, NSApplicationDelegate {
    let info = Bundle.main.infoDictionary ?? [:]
    lazy var vmPath = info[GuestAppProxy.InfoKey.vmPath] as? String ?? ""
    lazy var key = info[GuestAppProxy.InfoKey.appKey] as? String
    lazy var launchID = info[GuestAppProxy.InfoKey.launchID] as? String
    lazy var host = info[GuestAppProxy.InfoKey.hostBundleID] as? String ?? GuestAppProxy.defaultHostBundleID
    let dockOnly = CommandLine.arguments.contains(GuestAppProxy.dockArgument)
    /// Set when Vitrine asked us to leave, so quitting doesn't also close the guest app.
    var quitByVitrine = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "png").flatMap(NSImage.init(contentsOf:))
        if let icon { NSApp.applicationIconImage = icon }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(control(_:)), name: GuestAppProxy.controlNotification, object: nil)
        if !dockOnly { requestLaunch() }
    }

    /// A launcher: ask Vitrine to start the guest app (starting Vitrine if needed). A launcher that
    /// can't be matched to its guest windows has nothing more to do; Vitrine's own Dock proxy
    /// takes over once the app shows windows.
    func requestLaunch() {
        guard let id = launchID else { return }
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: host).isEmpty
        if running {
            post(.launch, extra: ["id": id])
        } else if let url = GuestAppProxy.launchURL(vmPath: vmPath, id: id),
                  let vitrine = NSWorkspace.shared.urlForApplication(withBundleIdentifier: host) {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: vitrine, configuration: config)
        }
        if key == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if dockOnly || key != nil { post(.activate) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        post(.activate)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitByVitrine, key != nil, !isSessionEnding,
              !NSRunningApplication.runningApplications(withBundleIdentifier: host).isEmpty else {
            return .terminateNow
        }
        // Ask the guest app to quit and stay: it may ask to save first (and the user may cancel).
        // Vitrine quits this proxy once the app's windows are really gone.
        post(.quit)
        return .terminateCancel
    }

    /// Log out, restart or shut down asked every app to quit: never hold that up.
    var isSessionEnding: Bool {
        // kAEQuitReason is a parameter of the quit event (not an attribute).
        guard let reason = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue else { return false }
        return [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAEShowShutdownDialog, kAERestart, kAEShutDown, kAEQuitAll]
            .map { OSType($0) }.contains(reason)
    }

    @objc func control(_ note: Notification) {
        guard let info = note.userInfo, info["vm"] as? String == vmPath, info["key"] as? String == key,
              info["command"] as? String == GuestAppProxy.Command.quit.rawValue else { return }
        quitByVitrine = true
        NSApp.terminate(nil)
    }

    func post(_ event: GuestAppProxy.Event, extra: [String: String] = [:]) {
        // The guest app's windows belong to Vitrine: let it take activation (cooperative activation).
        if event == .activate || event == .launch {
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: host)
        }
        var info = extra
        info["vm"] = vmPath
        info["event"] = event.rawValue
        if let key { info["key"] = key }
        DistributedNotificationCenter.default().postNotificationName(
            GuestAppProxy.eventNotification, object: nil, userInfo: info, deliverImmediately: true)
    }
}

let app = NSApplication.shared
let delegate = ProxyDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
