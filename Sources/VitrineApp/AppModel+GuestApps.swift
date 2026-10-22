import AppKit
import VitrineCore
import VitrineVZ
import VitrineAgentHost
import VitrineAgentProtocol

/// Guest apps on the Mac: Dock icons in Coherence, launchers, and requests from both.
extension AppModel {
    /// Routes the guest's app replies (icons, catalog) for one agent session.
    func wireGuestApps(_ bundle: VMBundle, session: AgentSession) {
        session.onAppIcon = { icon in GuestAppDock.shared.receivedIcon(bundle, icon) }
        session.onAppCatalog = { [weak self] catalog in self?.catalogWaiters.removeValue(forKey: bundle.url.path)?(catalog) }
    }

    /// Listens for proxy apps (Dock icon clicked, Quit, launcher opened).
    /// Registered from applicationDidFinishLaunching: observers added while the SwiftUI model is
    /// being created (before the app finished launching) never received these notifications.
    static func observeGuestAppProxies() -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: GuestAppProxy.eventNotification, object: nil, queue: .main) { note in
            var info: [String: String] = [:]
            for (k, v) in note.userInfo ?? [:] { if let k = k as? String, let v = v as? String { info[k] = v } }
            MainActor.assumeIsolated { AppModel.shared?.handleProxyEvent(info) }
        }
    }

    func handleProxyEvent(_ info: [String: String]) {
        guard let vm = info["vm"], let raw = info["event"], let event = GuestAppProxy.Event(rawValue: raw),
              bundles.contains(where: { $0.url.path == vm }) else { return }
        let bundle = VMBundle(url: URL(fileURLWithPath: vm))
        switch event {
        case .launch:
            if let id = info["id"] { launchGuestApp(bundle, id: id) }
        case .activate:
            if let key = info["key"] {
                let n = coherenceController(for: bundle)?.activateApp(key: key) ?? -1
                controller(for: bundle)?.note("Dock: activate \((key as NSString).lastPathComponent) (\(n) window(s))")
            }
        case .quit:
            if let key = info["key"] { coherenceController(for: bundle)?.closeApp(key: key) }
        }
    }

    /// vitrine://launch?vm=…&id=… (a launcher found Vitrine not running), and VM actions for
    /// Shortcuts and scripts: vitrine://start|show|suspend|stop?vm=<VM name>.
    func handle(url: URL) {
        if let (vm, id) = GuestAppProxy.parseLaunchURL(url) {
            guard bundles.contains(where: { $0.url.path == vm }) else { return }
            launchGuestApp(VMBundle(url: URL(fileURLWithPath: vm)), id: id)
            return
        }
        guard url.scheme == "vitrine", let action = url.host,
              let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "vm" })?.value,
              let bundle = bundles.first(where: { $0.name == name }) else { return }
        let running = controller(for: bundle).map { $0.state == .running || $0.state == .paused } ?? false
        switch action {
        case "start", "show":
            if !running { start(bundle) }
            if let w = displayWindows[bundle.url.path] { w.makeKeyAndOrderFront(nil) }
            else if action == "show" { openVMWindow?(bundle.url.path) }
            NSApp.activate()
        case "suspend":
            if running { suspend(bundle) }
        case "stop":
            // Any web page can open a vitrine:// link: shutting a VM down (unsaved guest work is lost)
            // needs the user's confirmation. Starting and suspending lose nothing.
            guard running else { return }
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = String(localized: "Shut down “\(bundle.name)”?")
            alert.informativeText = String(localized: "A link or shortcut asked Vitrine to shut this virtual machine down. Unsaved work in the guest will be lost.")
            alert.addButton(withTitle: String(localized: "Shut Down"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            if alert.runModal() == .alertFirstButtonReturn { stop(bundle) }
        default:
            break
        }
    }

    /// Starts the VM if needed, waits for its agent, opens the app and shows it in Coherence. Only
    /// apps exported as launchers can be opened this way (requests come from other processes).
    func launchGuestApp(_ bundle: VMBundle, id: String) {
        guard let c = controller(for: bundle) else { return }
        guard GuestAppDock.isExportedLaunchID(bundle, id) else {
            c.note("refused to launch \"\(id.prefix(120))\": not one of the exported launchers")
            return
        }
        Task {
            do {
                if c.state == .stopped || c.state == .suspended || c.state == .error { try await c.start() }
                if c.state == .paused { try await c.resume() }
                let session = try await waitForAgent(c, timeout: 240)
                // Agents without "apps" don't know the message and would drop the connection.
                guard session.guestHello?.capabilities.contains("apps") == true else {
                    throw VitrineError.unsupported("the Vitrine Agent in \(bundle.name) is too old to open apps; update it (Actions → Install Vitrine Agent)")
                }
                session.send(.launchApp(LaunchApp(id: id)))
                if !coherenceActive.contains(bundle.url.path), session.guestHello?.capabilities.contains("coherence") == true {
                    enterCoherence(bundle)
                }
            } catch { report(error, "Could not open the app") }
        }
    }

    func waitForAgent(_ c: VirtualMachineController, timeout: TimeInterval) async throws -> AgentSession {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let s = c.agent, s.guestHello != nil { return s }
            guard c.state == .running || c.state == .starting else { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw VitrineError.backend("the Vitrine Agent in \(c.bundle.name) didn't connect")
    }

    /// Writes launchers for every guest app into ~/Applications/Vitrine Apps/<VM> (Launchpad, Spotlight).
    func createLaunchers(_ bundle: VMBundle) {
        guard let c = controller(for: bundle), let session = c.agent, session.guestHello != nil else {
            alert = .init(title: String(localized: "Vitrine Agent not connected"), message: String(localized: "Start the VM and wait for the agent to connect."))
            return
        }
        guard session.guestHello?.capabilities.contains("apps") == true else {
            alert = .init(title: String(localized: "Agent too old"), message: String(localized: "Update the Vitrine Agent in the VM (Actions → Install Vitrine Agent)."))
            return
        }
        wireGuestApps(bundle, session: session)
        let path = bundle.url.path
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.catalogWaiters.removeValue(forKey: path) != nil else { return }
            self.alert = .init(title: String(localized: "No answer from the VM"), message: String(localized: "The agent didn't send its app list."))
        }
        catalogWaiters[path] = { [weak self] catalog in
            timeout.cancel()
            Task { @MainActor in
                guard let self else { return }
                do {
                    let (folder, count) = try await GuestAppDock.shared.writeLaunchers(bundle, catalog: catalog)
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                    self.alert = .init(title: String(localized: "\(count) apps added"),
                                       message: String(localized: "Launchers for \(bundle.name) are in \(folder.path). They also appear in Launchpad and Spotlight."))
                } catch { self.report(error, "Could not create launchers") }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: timeout)
        session.send(.appCatalogRequest(AppCatalogRequest(iconSize: 128)))
    }
}
