import SwiftUI
import VitrineCore
import VitrineVZ
import VitrineAgentHost

@main
struct VitrineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    init() {
        // Broken pipes (ssh exiting early, guest agent dropping) must surface as errors, not kill the app.
        signal(SIGPIPE, SIG_IGN)
        // Run locks taken by this process say "app", so vitrinectl asks us instead of signalling.
        VMBundle.processRole = .app
    }

    var body: some Scene {
        Window("Control Center", id: "control-center") {
            ControlCenterView()
                .environmentObject(model)
                .onAppear { model.autoStartIfNeeded() }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 420, height: 480)
        .commands { VitrineCommands(model: model) }

        Window("Installation Assistant", id: "assistant") {
            InstallationAssistantView().environmentObject(model)
        }
        .windowResizability(.contentSize)

        WindowGroup("Configuration", id: "config", for: String.self) { $path in
            if let path {
                ConfigurationView(bundle: VMBundle(url: URL(fileURLWithPath: path))).environmentObject(model)
            }
        }
        .windowResizability(.contentMinSize)

        WindowGroup("Virtual Machine", id: "vm", for: String.self) { $path in
            if let path {
                VMWindowView(bundle: VMBundle(url: URL(fileURLWithPath: path))).environmentObject(model)
            }
        }
        .windowToolbarStyle(.unifiedCompact)

        Settings {
            SettingsView()
        }

        MenuBarExtra {
            StatusMenu().environmentObject(model)
        } label: {
            Image(systemName: model.coherenceActive.isEmpty ? "square.on.square" : "square.on.square.fill")
        }
    }
}

/// Focused VM (bundle path) of the key VM window, for the Actions/View menus.
struct FocusedVMKey: FocusedValueKey { typealias Value = String }
extension FocusedValues {
    var focusedVM: String? {
        get { self[FocusedVMKey.self] }
        set { self[FocusedVMKey.self] = newValue }
    }
}

struct VitrineCommands: Commands {
    @ObservedObject var model: AppModel
    @FocusedValue(\.focusedVM) var focusedVM
    @Environment(\.openWindow) private var openWindow
    @AppStorage(VMStatusBar.visibilityKey) private var showStatusBar = true

    var bundle: VMBundle? { focusedVM.map { VMBundle(url: URL(fileURLWithPath: $0)) } }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New…") { openWindow(id: "assistant") }.keyboardShortcut("n")
        }
        CommandGroup(after: .windowArrangement) {
            Button("Control Center") { openWindow(id: "control-center") }.keyboardShortcut("1", modifiers: [.command, .option])
        }
        CommandMenu("Actions") {
            if let b = bundle, let c = model.controller(for: b) {
                let running = c.state == .running || c.state == .paused
                Button(running ? (c.state == .paused ? "Resume" : "Pause") : (c.state == .suspended ? "Resume" : "Start")) {
                    running ? model.togglePause(b) : model.start(b)
                }.keyboardShortcut("p", modifiers: [.command, .control])
                Button("Suspend") { model.suspend(b) }.disabled(!running)
                Button("Shut Down") { model.stop(b) }.disabled(!running)
                Button("Restart") { model.restart(b) }.disabled(!running)
                Button("Force Stop") { model.stop(b, force: true) }.disabled(!running)
                Divider()
                Button("Take Snapshot…") { model.configTab = .snapshots; openWindow(id: "config", value: b.url.path) }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                Button("Manage Snapshots…") { model.configTab = .snapshots; openWindow(id: "config", value: b.url.path) }
                Divider()
                Menu("Send Key") {
                    ForEach(SendKeyCombo.allCases) { combo in
                        Button(combo.title) { model.sendKeys(combo, to: b) }
                    }
                }
                .disabled(c.state != .running)
                Button("Open Serial Console") { model.openSerialConsole(b) }
                    .disabled(c.state != .running || c.config.guestOS == .macOS)
                Divider()
                Button("Install Vitrine Agent") { model.installAgent(b) }.disabled(c.state != .running)
                if c.config.guestOS == .macOS {
                    Button("Allow Vitrine Agent Control…") { model.allowAgentControl(b) }
                        .disabled(c.state != .running || !c.agentLacksPermissions)
                }
                Button("Add Apps to Launchpad") { model.createLaunchers(b) }.disabled(c.state != .running)
                Button("Configure…") { model.configTab = .general; openWindow(id: "config", value: b.url.path) }
                    .keyboardShortcut(",", modifiers: [.command, .shift])
            } else {
                Text("No virtual machine selected")
            }
        }
        CommandMenu("Devices") {
            if let b = bundle, let c = model.controller(for: b) {
                USBMenuItems(bundle: b, controller: c)
            } else {
                Text("No virtual machine selected")
            }
        }
        CommandGroup(before: .toolbar) {
            // Coherence windows aren't VM windows, so offer "Exit" whenever any VM is in Coherence.
            if bundle == nil, let active = model.coherenceActive.first {
                Button("Exit Seamless Mode") { model.exitCoherence(VMBundle(url: URL(fileURLWithPath: active))) }
                    .keyboardShortcut("c", modifiers: [.command, .control])
                Divider()
            }
            if let b = bundle {
                Button(model.coherenceActive.contains(b.url.path) ? "Exit Seamless Mode" : "Enter Seamless Mode") {
                    model.toggleCoherence(b)
                }
                .keyboardShortcut("c", modifiers: [.command, .control])
                Button(model.pictureInPicture.contains(b.url.path) ? "Exit Picture in Picture" : "Enter Picture in Picture") {
                    model.togglePictureInPicture(b)
                }
                .keyboardShortcut("p", modifiers: [.command, .control, .option])
                Button("Toggle Full Screen") { model.toggleFullScreen(b) }
                    .keyboardShortcut("f", modifiers: [.command, .control])
                Button(showStatusBar ? "Hide Status Bar" : "Show Status Bar") { showStatusBar.toggle() }
                    .keyboardShortcut("/")
                Divider()
            }
        }
    }
}

/// Menu bar icon menu: VMs with quick actions .
struct StatusMenu: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Control Center") { openWindow(id: "control-center"); NSApp.activate() }
        Divider()
        ForEach(model.bundles, id: \.self) { b in
            if let c = model.controller(for: b) {
                StatusMenuItem(bundle: b, controller: c)
            }
        }
        Divider()
        Button("New…") { openWindow(id: "assistant"); NSApp.activate() }
        Button("Quit Vitrine") { NSApp.terminate(nil) }
    }
}

private struct StatusMenuItem: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let bundle: VMBundle
    @ObservedObject var controller: VirtualMachineController

    var body: some View {
        Menu("\(bundle.name) — \(controller.state.label)") {
            VMActionsMenu(bundle: bundle, controller: controller)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var demo: (SyntheticGuest, CoherenceController)?
    private var guestAppObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        guestAppObserver = AppModel.observeGuestAppProxies()
        AppModel.shared?.startUSBMonitor()
        if CommandLine.arguments.contains("--coherence-demo") { startCoherenceDemo() }
        if let i = CommandLine.arguments.firstIndex(of: "--start"), i + 1 < CommandLine.arguments.count {
            let name = CommandLine.arguments[i + 1]
            let coherence = CommandLine.arguments.contains("--coherence")
            Task { @MainActor in await self.autoStart(name: name, coherence: coherence) }
        }
    }

    /// `--start <vm> [--coherence]`: start/resume a VM and optionally enter Coherence once the agent is up.
    @MainActor private func autoStart(name: String, coherence: Bool) async {
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard let model = AppModel.shared, let bundle = try? VMLibrary.find(name),
              let c = model.controller(for: bundle) else { return }
        model.start(bundle)
        guard coherence else { return }
        for _ in 0..<240 {
            if c.state == .running, c.agent?.guestHello != nil {
                model.enterCoherence(bundle)
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// vitrine://launch URLs from guest app launchers (sent when Vitrine wasn't running).
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            // On a cold launch the model may not exist yet.
            for _ in 0..<40 where AppModel.shared == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            for url in urls { AppModel.shared?.handle(url: url) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock icon menu: start or show each VM.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let model = AppModel.shared else { return nil }
        let menu = NSMenu()
        for b in model.bundles {
            guard let c = model.controller(for: b) else { continue }
            let running = c.state == .running || c.state == .paused
            let item = NSMenuItem(title: "\(b.name) — \(c.state.label)", action: #selector(dockVMAction(_:)), keyEquivalent: "")
            item.representedObject = b.url.path
            item.target = self
            item.toolTip = running ? String(localized: "Show") : String(localized: "Start")
            menu.addItem(item)
        }
        return menu
    }

    @MainActor @objc private func dockVMAction(_ item: NSMenuItem) {
        guard let path = item.representedObject as? String, let model = AppModel.shared else { return }
        let b = VMBundle(url: URL(fileURLWithPath: path))
        if let c = model.controller(for: b), c.state != .running && c.state != .paused { model.start(b) }
        if let w = model.displayWindows[path] { w.makeKeyAndOrderFront(nil) }
        NSApp.activate()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = AppModel.shared else { return .terminateNow }
        // Dock icons go only once quitting is certain (the user may still cancel below).
        let removeDockIcons = { MainActor.assumeIsolated { for b in model.bundles { GuestAppDock.shared.removeAll(b) } } }
        guard !model.liveControllers.isEmpty else { removeDockIcons(); return .terminateNow }
        // VMs with a drive attached can't be suspended safely: ask before shutting them down.
        let blocked = MainActor.assumeIsolated { model.activeControllers.filter { $0.suspendBlocker != nil } }
        if !blocked.isEmpty {
            let alert = NSAlert()
            let names = ListFormatter.localizedString(byJoining: blocked.map(\.bundle.name))
            alert.messageText = String(localized: "USB drives are connected to \(names)")
            alert.informativeText = String(localized: "Vitrine can't suspend a VM while a drive is connected (the guest may not have written everything to it yet). Eject the drive in the guest and disconnect it, or shut the VM down before quitting.")
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addButton(withTitle: String(localized: "Shut Down and Quit"))
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        removeDockIcons()
        Task { @MainActor in
            await model.suspendAllForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Runs Coherence against a synthetic guest (no VM): two windows cropped from a four-colour
    /// framebuffer, mapped onto the main screen. Useful for checking rendering and input plumbing.
    @MainActor private func startCoherenceDemo() {
        guard let screen = NSScreen.main else { return }
        let guest = SyntheticGuest(widthPoints: Int(screen.frame.width), heightPoints: Int(screen.frame.height),
                                   scale: screen.backingScaleFactor)
        let cc = CoherenceController(session: guest.hostSession, screen: screen)
        guest.hostSession.onStateChange = { state in
            if case .ready = state { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { cc.start() } }
        }
        guest.start()
        demo = (guest, cc)
    }
}
