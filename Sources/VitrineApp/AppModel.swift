import SwiftUI
import AppKit
import Combine
import VitrineCore
import VitrineVZ
import VitrineAgentHost
import VitrineAgentProtocol
import VitrineQEMU
import Virtualization

/// App-wide state: the VM library, live controllers, and Coherence sessions.
@MainActor
final class AppModel: ObservableObject {
    @Published var bundles: [VMBundle] = []
    @Published var selection: VMBundle?
    /// Setting it shows the alert at once, on whichever window is in front (not only the Control
    /// Center, which may be closed while the user works in a VM window).
    var alert: AlertItem? {
        didSet { if let alert { present(alert) } }
    }
    @Published var configTab: ConfigTab = .general
    /// Bundle paths currently in Coherence mode.
    @Published var coherenceActive: Set<String> = []
    /// VMs the user put in Coherence: if the agent reconnects (guest reboot, agent update) Coherence
    /// resumes automatically instead of silently ending.
    private var coherenceDesired: Set<String> = []

    private var controllers: [String: VirtualMachineController] = [:]
    private var coherence: [String: CoherenceController] = [:]
    private var sinks: [String: DisplaySink] = [:]
    private var coherenceSessions: [String: AgentSession] = [:]
    /// Window frames saved while in Picture in Picture.
    private var pipSavedFrames: [String: NSRect] = [:]
    @Published var pictureInPicture: Set<String> = []
    /// Display windows by bundle path, captured by WindowAccessor so Coherence can hide them.
    var displayWindows: [String: NSWindow] = [:]
    /// Opens a VM's display window (SwiftUI's openWindow, handed over by the Control Center) for
    /// code outside views, such as vitrine://show.
    var openVMWindow: ((String) -> Void)?
    private var subscriptions: [String: AnyCancellable] = [:]
    /// Pending app-catalog requests by bundle path (see createLaunchers).
    var catalogWaiters: [String: (AppCatalog) -> Void] = [:]

    struct AlertItem: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        /// A button besides Cancel, and what it does.
        var action: (title: String, run: () -> Void)? = nil
    }

    /// A sheet on the front titled window, or a dialog of its own when there is none (in seamless
    /// mode every visible window is a borderless guest window).
    private func present(_ item: AlertItem) {
        let a = NSAlert()
        a.messageText = item.title
        a.informativeText = item.message
        if let action = item.action {
            a.addButton(withTitle: action.title)
            a.addButton(withTitle: String(localized: "Cancel"))
        }
        let respond: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { item.action?.run() }
        }
        func usable(_ w: NSWindow?) -> NSWindow? {
            guard let w, w.isVisible, w.styleMask.contains(.titled), w.attachedSheet == nil else { return nil }
            return w
        }
        if let w = usable(NSApp.keyWindow) ?? usable(NSApp.mainWindow) ?? NSApp.orderedWindows.lazy.compactMap(usable).first {
            a.beginSheetModal(for: w, completionHandler: respond)
        } else {
            NSApp.activate()
            respond(a.runModal())
        }
    }

    private var didAutoStart = false
    /// The app's single model, for AppKit callbacks (quit handling).
    static weak var shared: AppModel?

    /// Bumped whenever thumbnails are refreshed so cards reload their image.
    @Published var thumbnailGeneration = 0
    private var thumbnailTimer: Timer?

    init() {
        refresh()
        AppModel.shared = self
        thumbnailTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshThumbnails() }
        }
        watchLibrary()
    }

    private var libraryWatch: DispatchSourceFileSystemObject?

    /// Re-lists the library when VMs are created, imported or deleted outside the app (vitrinectl).
    private func watchLibrary() {
        let fd = open(VMLibrary.root.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            // Again a moment later: a new bundle's directory appears before its configuration.
            MainActor.assumeIsolated { self?.refresh() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { self?.refresh() } }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        libraryWatch = source
    }

    /// Saves a thumbnail of every visible running VM (live Control Center cards).
    func refreshThumbnails() {
        var changed = false
        for (path, window) in displayWindows where window.isVisible {
            guard let c = controllers[path], c.state == .running, let view = window.contentView else { continue }
            if Thumbnailer.save(from: view, to: c.bundle.thumbnailURL) { changed = true }
        }
        if changed { thumbnailGeneration += 1 }
    }

    /// Thumbnail right before the display goes away (suspend / shut down).
    func captureThumbnail(_ bundle: VMBundle) {
        if let view = displayWindows[bundle.url.path]?.contentView, Thumbnailer.save(from: view, to: bundle.thumbnailURL) {
            thumbnailGeneration += 1
        }
    }

    /// VMs that are running or paused.
    var activeControllers: [VirtualMachineController] {
        controllers.values.filter { $0.state == .running || $0.state == .paused }
    }

    /// VMs with a live backend, including ones mid-transition (starting, suspending, stopping).
    var liveControllers: [VirtualMachineController] {
        controllers.values.filter {
            $0.qemu != nil || $0.virtualMachine != nil || ![.stopped, .suspended, .error].contains($0.state)
        }
    }

    /// On quit, suspend every running VM so nothing is powered off mid-write.
    func suspendAllForQuit() async {
        for c in activeControllers { captureThumbnail(c.bundle) }
        for key in coherenceActive { exitCoherence(VMBundle(url: URL(fileURLWithPath: key))) }
        // Let in-flight transitions (a suspend already saving, a VM still booting) settle first.
        let settle = Date().addingTimeInterval(120)
        while liveControllers.contains(where: { $0.state != .running && $0.state != .paused }), Date() < settle {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        await withTaskGroup(of: Void.self) { group in
            for c in activeControllers {
                group.addTask { @MainActor in
                    if c.suspendBlocker != nil || c.config.features.disposable {
                        // A drive is attached (the user chose to shut down), or the VM is disposable
                        // (nothing to keep): give the guest time to flush and power off; slow
                        // (emulated) guests need minutes.
                        await c.stop(timeout: 300)
                        return
                    }
                    do { try await c.suspend() } catch { await c.stop(timeout: 60) }
                }
            }
        }
        // Never leave a backend running behind a quitting app.
        for c in liveControllers { await c.forceStop() }
    }

    func refresh() {
        try? FileManager.default.createDirectory(at: VMLibrary.root, withIntermediateDirectories: true)
        bundles = VMLibrary.list()
        for b in bundles { controllers[b.url.path]?.reloadConfig() }
        if let sel = selection, !bundles.contains(sel) { selection = nil }
    }

    /// Starts VMs marked "Start when Vitrine opens" (once per launch).
    func autoStartIfNeeded() {
        guard !didAutoStart else { return }
        didAutoStart = true
        for b in bundles where (try? b.loadConfig())?.features.startWithVitrine == true && b.runningPID() == nil {
            start(b)
        }
    }

    /// Applies the VM's "when window is closed" option.
    func windowClosed(_ bundle: VMBundle) {
        guard let c = controllers[bundle.url.path], c.state == .running || c.state == .paused,
              !coherenceActive.contains(bundle.url.path) else { return }
        switch c.config.features.closeAction {
        case .suspend where c.config.features.disposable: stop(bundle) // its state is discarded anyway
        case .suspend: suspend(bundle, shuttingDownIfBlocked: true)
        case .shutDown: stop(bundle)
        case .keepRunning: break
        case .ask:
            let alert = NSAlert()
            alert.messageText = String(localized: "“\(bundle.name)” is still running")
            alert.informativeText = String(localized: "What do you want to do with the virtual machine?")
            alert.addButton(withTitle: String(localized: "Suspend"))
            alert.addButton(withTitle: String(localized: "Shut Down"))
            alert.addButton(withTitle: String(localized: "Keep Running"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: suspend(bundle, shuttingDownIfBlocked: true)
            case .alertSecondButtonReturn: stop(bundle)
            default: break
            }
        }
    }

    func restart(_ bundle: VMBundle) {
        guard let c = controllers[bundle.url.path] else { return }
        exitCoherence(bundle)
        Task {
            await c.stop()
            do { try await c.start() } catch { report(error, "Could not restart \(bundle.name)") }
        }
    }

    func controller(for bundle: VMBundle) -> VirtualMachineController? {
        if let c = controllers[bundle.url.path] { return c }
        guard let c = try? VirtualMachineController(bundle: bundle) else { return nil }
        controllers[bundle.url.path] = c
        // Screenshots and input over the control socket use whichever view presents the guest.
        c.displayViewProvider = { [weak self] in
            guard let self else { return nil }
            if let v = self.vmView(for: bundle) as? GuestDisplayView, v.virtualMachine != nil { return v }
            return self.sinks[bundle.url.path]?.view
        }
        // `vitrinectl stop|suspend` go through the same actions as the UI.
        c.lifecycleRequestHandler = { [weak self] op in
            switch op {
            case .suspend: self?.suspend(bundle)
            case .forceStop: self?.stop(bundle, force: true)
            default: self?.stop(bundle)
            }
        }
        // Leave Coherence automatically if the VM stops or the agent drops.
        subscriptions[bundle.url.path] = c.objectWillChange.sink { [weak self, weak c] in
            DispatchQueue.main.async {
                guard let self, let c else { return }
                let key = bundle.url.path
                if self.coherenceActive.contains(key), c.state != .running || c.agent == nil
                    || self.coherenceSessions[key] !== c.agent {
                    self.exitCoherence(bundle, userInitiated: false)
                }
                if c.state != .running { self.coherenceDesired.remove(key) }
                if self.coherenceDesired.contains(key), !self.coherenceActive.contains(key),
                   c.state == .running, c.agent?.guestHello != nil {
                    self.enterCoherence(bundle)
                }
            }
        }
        return c
    }

    func report(_ error: Error, _ title: String.LocalizationValue = "Something went wrong") {
        alert = AlertItem(title: String(localized: title), message: error.localizedDescription)
    }

    // MARK: Lifecycle actions

    func start(_ bundle: VMBundle, recovery: Bool = false) {
        guard let c = controller(for: bundle) else { return }
        Task {
            do { try await c.start(recovery: recovery) } catch { report(error, "Could not start \(bundle.name)") }
        }
    }

    func stop(_ bundle: VMBundle, force: Bool = false) {
        guard let c = controllers[bundle.url.path] else { return }
        captureThumbnail(bundle)
        Task { if force { await c.forceStop() } else { await c.stop() } }
    }

    func suspend(_ bundle: VMBundle, shuttingDownIfBlocked: Bool = false) {
        guard let c = controllers[bundle.url.path] else { return }
        captureThumbnail(bundle)
        exitCoherence(bundle)
        Task {
            if shuttingDownIfBlocked {
                let generation = c.qemu
                let migrationBlocker = await generation?.migrationBlocker()
                guard c.qemu === generation, c.state == .running || c.state == .paused else { return }
                if c.suspendBlocker != nil || migrationBlocker != nil {
                    await c.stop()
                    return
                }
            }
            do { try await c.suspend() } catch { report(error, "Could not suspend") }
        }
    }

    // MARK: USB

    func attachUSB(_ bundle: VMBundle, _ attachment: USBAttachment) {
        guard let c = controllers[bundle.url.path] else { return }
        Task {
            do {
                let (_, warning) = try await c.attachUSB(attachment)
                if let warning {
                    alert = .init(title: String(localized: "\(attachment.localizedLabel) may not work"),
                                  message: String(localized: "QEMU reported:\n\(warning)\n\nmacOS keeps USB devices its own drivers use; those can only be passed to Windows VMs when QEMU runs as root."))
                }
            } catch { report(error, "Could not attach \(attachment.localizedLabel)") }
        }
    }

    func detachUSB(_ bundle: VMBundle, id: String) {
        guard let c = controllers[bundle.url.path] else { return }
        Task { do { try await c.detachUSB(id: id) } catch { report(error, "Could not eject") } }
    }

    /// Asks for a disk image and plugs it in as a USB drive.
    func attachUSBImage(_ bundle: VMBundle) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Attach a Disk Image as a USB Drive")
        panel.prompt = String(localized: "Attach")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let readOnly = NSButton(checkboxWithTitle: String(localized: "Read-only"), target: nil, action: nil)
        panel.accessoryView = readOnly
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attachUSB(bundle, .image(path: url.path, readOnly: readOnly.state == .on))
    }

    func togglePause(_ bundle: VMBundle) {
        guard let c = controllers[bundle.url.path] else { return }
        Task {
            do { if c.state == .paused { try await c.resume() } else { try await c.pause() } }
            catch { report(error) }
        }
    }

    func delete(_ bundle: VMBundle) {
        do {
            try bundle.deleteSafely(trash: true)
            controllers[bundle.url.path] = nil
            refresh()
        } catch { report(error) }
    }

    func clone(_ bundle: VMBundle) {
        var n = 2
        var name = "\(bundle.name) \(n)"
        while FileManager.default.fileExists(atPath: VMLibrary.bundleURL(named: name).path) { n += 1; name = "\(bundle.name) \(n)" }
        do {
            let out = try VMCloner.clone(bundle, to: VMLibrary.bundleURL(named: name), newName: name)
            refresh()
            selection = out
        } catch { report(error, "Clone failed") }
    }

    func installAgent(_ bundle: VMBundle) {
        Task {
            do {
                _ = try await AgentInstaller.install(into: bundle)
                alert = .init(title: String(localized: "Vitrine Agent installed"),
                              message: String(localized: "Inside the VM, allow “Vitrine Agent” under Privacy & Security → Screen & System Audio Recording and Accessibility to enable Coherence."))
            } catch { report(error, "Agent installation failed") }
        }
    }

    // MARK: Coherence

    func coherenceController(for bundle: VMBundle) -> CoherenceController? { coherence[bundle.url.path] }

    func toggleCoherence(_ bundle: VMBundle) {
        if coherenceActive.contains(bundle.url.path) { exitCoherence(bundle) } else { enterCoherence(bundle) }
    }

    /// Has a macOS guest ask its user to allow Vitrine Agent what seamless mode needs; agents don't
    /// ask on their own, so this is the user's explicit choice.
    func allowAgentControl(_ bundle: VMBundle) {
        guard let c = controllers[bundle.url.path], c.state == .running else { return }
        guard c.agent?.guestHello != nil else {
            alert = .init(title: String(localized: "Vitrine Agent not connected"),
                          message: String(localized: "Seamless mode needs the Vitrine Agent running inside the VM. Choose Actions ▸ Install Vitrine Agent."))
            return
        }
        guard c.requestAgentPermissions() else {
            alert = .init(title: String(localized: "Agent too old"),
                          message: String(localized: "Update the Vitrine Agent in the VM (Actions → Install Vitrine Agent)."))
            return
        }
        alert = .init(title: String(localized: "Allow Vitrine Agent in the VM"),
                      message: String(localized: "The VM now asks you to let Vitrine Agent record the screen and control the computer, which seamless mode needs. Allow both there; the agent then restarts by itself to use them."))
    }

    func enterCoherence(_ bundle: VMBundle) {
        guard let c = controllers[bundle.url.path], c.state == .running else { return }
        guard let session = c.agent, let hello = session.guestHello else {
            alert = .init(title: String(localized: "Vitrine Agent not connected"),
                          message: String(localized: "Seamless mode needs the Vitrine Agent running inside the VM. Choose Actions ▸ Install Vitrine Agent."))
            return
        }
        guard hello.capabilities.contains("coherence") else {
            // Current macOS agents ask for their permissions only when the user wants them to.
            if c.config.guestOS == .macOS, hello.capabilities.contains("permissions") {
                alert = .init(title: String(localized: "Seamless mode needs permission"),
                              message: String(localized: "Seamless mode needs Vitrine Agent to record the screen and control the computer inside the VM. Ask in the VM, allow both there, and try again once the agent has restarted (a few seconds)."),
                              action: (String(localized: "Ask in the VM"), { _ = c.requestAgentPermissions() }))
                return
            }
            alert = .init(title: String(localized: "Screen Recording permission needed"),
                          message: String(localized: "Inside the VM, open System Settings → Privacy & Security → Screen & System Audio Recording and enable “Vitrine Agent”, then try again."))
            return
        }
        guard let screen = displayWindows[bundle.url.path]?.screen ?? NSScreen.main else { return }
        if c.qemu != nil {
            enterQEMUCoherence(bundle, controller: c, session: session, screen: screen)
            return
        }
        guard let vm = c.virtualMachine else { return }
        // Match the guest display to the host screen so windows map 1:1.
        // macOS guests render HiDPI natively. Linux/X11 guests get full pixels only when their desktop
        // runs at 2× (agent reports scale 2, e.g. Xft.dpi 192); otherwise 1× in host points.
        let guestHiDPI = c.config.guestOS == .macOS || (session.display?.scale ?? 1) >= 2
        let px: (width: Int, height: Int, ppi: Int) = guestHiDPI
            ? CoherenceDisplay.pixels(for: screen)
            : (Int(screen.frame.width), Int(screen.frame.height), 110)
        let cc = activateCoherence(bundle, controller: c, session: session, screen: screen)
        // The VM window gets hidden; an invisible sink keeps the display presented (required for
        // reconfiguration) without resizing the guest to a window.
        vmView(for: bundle)?.virtualMachine = nil
        sinks[bundle.url.path] = DisplaySink(virtualMachine: vm, screen: screen)
        displayWindows[bundle.url.path]?.orderOut(nil)
        c.reconfigureDisplayWhenReady(widthPixels: px.width, heightPixels: px.height, pixelsPerInch: px.ppi)
        // The agent restarts capture when the guest resolution changes, so starting early is fine.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak cc] in
            // Coherence may have been exited (or re-entered) during the delay.
            guard let self, let cc, self.coherence[bundle.url.path] === cc else { return }
            cc.start()
        }
    }

    /// Coherence for QEMU guests (Windows): no VZ display to keep presented; the guest is asked for
    /// the screen's size over VNC, and the geometry scales whatever mode the display driver picks.
    private func enterQEMUCoherence(_ bundle: VMBundle, controller c: VirtualMachineController, session: AgentSession,
                                    screen: NSScreen) {
        let cc = activateCoherence(bundle, controller: c, session: session, screen: screen)
        displayWindows[bundle.url.path]?.orderOut(nil)
        let size = (Int(screen.frame.width), Int(screen.frame.height))
        Task { [weak self, weak cc] in
            _ = try? await QEMUMachine.setDisplaySize(bundle: bundle, width: size.0, height: size.1)
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self, let cc, self.coherence[bundle.url.path] === cc else { return }
            cc.start()
        }
    }

    /// Creates and registers the Coherence controller for `bundle`, wired to its session and VM.
    /// The caller starts it once the guest display fits `screen`.
    private func activateCoherence(_ bundle: VMBundle, controller c: VirtualMachineController, session: AgentSession,
                                   screen: NSScreen) -> CoherenceController {
        let cc = CoherenceController(session: session, screen: screen)
        coherenceSessions[bundle.url.path] = session
        coherenceDesired.insert(bundle.url.path)
        cc.onExit = { [weak self] in self?.exitCoherence(bundle) }
        cc.onFileDrop = { [weak c] urls, point in c?.dropFiles(urls, guestPoint: point) }
        wireGuestApps(bundle, session: session)
        cc.onAppsChanged = { [weak session] apps in
            guard let session else { return }
            GuestAppDock.shared.update(bundle, session: session, apps: apps)
        }
        coherence[bundle.url.path] = cc
        coherenceActive.insert(bundle.url.path)
        return cc
    }

    func exitCoherence(_ bundle: VMBundle, userInitiated: Bool = true) {
        let key = bundle.url.path
        if userInitiated { coherenceDesired.remove(key) }
        coherenceSessions[key] = nil
        guard coherenceActive.contains(key) else { return }
        coherence[key]?.stop()
        coherence[key] = nil
        coherenceActive.remove(key)
        GuestAppDock.shared.removeAll(bundle)
        sinks[key]?.close()
        sinks[key] = nil
        if let c = controllers[key], let view = vmView(for: bundle) {
            view.automaticallyReconfiguresDisplay = c.config.display.autoResize
            view.virtualMachine = c.virtualMachine // with auto-resize this also resizes the guest to the window
        }
        if let c = controllers[key], c.state == .running, c.qemu != nil {
            let d = c.config.display
            Task { _ = try? await QEMUMachine.setDisplaySize(bundle: bundle, width: d.widthPixels, height: d.heightPixels) }
        } else if let c = controllers[key], c.state == .running, !c.config.display.autoResize {
            c.reconfigureDisplay(widthPixels: c.config.display.widthPixels, heightPixels: c.config.display.heightPixels)
        }
        displayWindows[key]?.makeKeyAndOrderFront(nil)
    }

    // MARK: View modes

    /// Picture in Picture: a small always-on-top window on every Space.
    func togglePictureInPicture(_ bundle: VMBundle) {
        let key = bundle.url.path
        guard let w = displayWindows[key] else { return }
        if pictureInPicture.contains(key) {
            pictureInPicture.remove(key)
            w.level = .normal
            w.collectionBehavior = [.managed, .participatesInCycle]
            if let f = pipSavedFrames.removeValue(forKey: key) { w.setFrame(f, display: true, animate: true) }
        } else {
            if coherenceActive.contains(key) { exitCoherence(bundle) }
            if w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
            pipSavedFrames[key] = w.frame
            pictureInPicture.insert(key)
            w.level = .floating
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let vis = (w.screen ?? NSScreen.main)?.visibleFrame ?? .zero
            let size = NSSize(width: 480, height: 300)
            w.setFrame(NSRect(x: vis.maxX - size.width - 20, y: vis.minY + 20, width: size.width, height: size.height),
                       display: true, animate: true)
        }
    }

    func toggleFullScreen(_ bundle: VMBundle) {
        if pictureInPicture.contains(bundle.url.path) { togglePictureInPicture(bundle) }
        if coherenceActive.contains(bundle.url.path) { exitCoherence(bundle) }
        displayWindows[bundle.url.path]?.toggleFullScreen(nil)
    }

    /// Opens the guest's serial console in Terminal (`vitrinectl console`; Ctrl-] detaches).
    func openSerialConsole(_ bundle: VMBundle) {
        guard let ctl = Bundle.main.url(forAuxiliaryExecutable: "vitrinectl") else {
            report(VitrineError.unsupported("vitrinectl is missing from the app bundle"), "Could not open the serial console")
            return
        }
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var script = "#!/bin/sh\nclear\n"
        if let home = ProcessInfo.processInfo.environment["VITRINE_HOME"] { script += "export VITRINE_HOME=\(quote(home))\n" }
        script += "exec \(quote(ctl.path)) console \(quote(bundle.name))\n"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Vitrine Console - \(bundle.name).command")
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
        } catch {
            report(error, "Could not open the serial console")
        }
    }

    /// Presses a key combination in the guest (Actions ▸ Send Key).
    func sendKeys(_ combo: SendKeyCombo, to bundle: VMBundle) {
        guard let c = controllers[bundle.url.path], c.state == .running else { return }
        if let q = c.qemu {
            Task { do { try await q.sendKeys(qcodes: combo.qcodes) } catch { report(error, "Could not send \(combo.title)") } }
        } else if let view = vmView(for: bundle) as? GuestDisplayView {
            view.send(combo)
        } else {
            report(VitrineError.unsupported("open the VM's window to send keys"), "Could not send \(combo.title)")
        }
    }

    /// The VZVirtualMachineView inside a VM's display window.
    func vmView(for bundle: VMBundle) -> VZVirtualMachineView? {
        func find(_ v: NSView) -> VZVirtualMachineView? {
            if let vm = v as? VZVirtualMachineView { return vm }
            for s in v.subviews { if let f = find(s) { return f } }
            return nil
        }
        return displayWindows[bundle.url.path]?.contentView.flatMap(find)
    }
}
