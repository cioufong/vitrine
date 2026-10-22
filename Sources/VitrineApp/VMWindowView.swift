import SwiftUI
import Virtualization
import VitrineCore
import VitrineVZ
import VitrineAgentHost
import VitrineQEMU

/// One window per VM: the guest display with a slim toolbar.
struct VMWindowView: View {
    @EnvironmentObject var model: AppModel
    let bundle: VMBundle

    var body: some View {
        if let c = model.controller(for: bundle) {
            VMWindowContent(bundle: bundle, controller: c)
                .focusedSceneValue(\.focusedVM, bundle.url.path)
        } else {
            Text("Cannot open \(bundle.url.path)").padding()
        }
    }
}

private struct VMWindowContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let bundle: VMBundle
    @ObservedObject var controller: VirtualMachineController
    @AppStorage(VMStatusBar.visibilityKey) private var showStatusBar = true
    @State private var permissionBannerHidden = false

    var running: Bool { controller.state == .running || controller.state == .paused }

    var body: some View {
        VStack(spacing: 0) {
            if running && controller.agentLacksPermissions && !permissionBannerHidden && !model.coherenceActive.contains(bundle.url.path) {
                AgentPermissionBanner(bundle: bundle, controller: controller) { permissionBannerHidden = true }
            }
            ZStack {
                Color.black
                if let q = controller.qemu, let rfb = q.rfb, running {
                    QEMUDisplayRepresentable(rfb: rfb, swapCommandOption: controller.config.features.swapCommandOption,
                                             pixelPerfect: controller.config.features.pixelPerfectScaling)
                    if controller.state == .paused { PausedOverlay { model.togglePause(bundle) } }
                } else if let vm = controller.virtualMachine, running {
                    // While in Coherence the guest display must stay at host-screen size, not follow this hidden window.
                    VMDisplayView(virtualMachine: vm,
                                  autoResize: controller.config.display.autoResize && !model.coherenceActive.contains(bundle.url.path),
                                  swapCommandOption: controller.config.features.swapCommandOption,
                                  onDrop: { urls in controller.dropFiles(urls) })
                    if controller.state == .paused { PausedOverlay { model.togglePause(bundle) } }
                } else {
                    IdleScreen(bundle: bundle, controller: controller)
                }
            }
            if running && showStatusBar && !model.coherenceActive.contains(bundle.url.path) {
                VMStatusBar(bundle: bundle, controller: controller)
            }
        }
        .background(WindowAccessor { window in
            model.displayWindows[bundle.url.path] = window
            window.tabbingMode = .disallowed
            window.titlebarAppearsTransparent = false
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { model.windowClosed(bundle) }
            }
        })
        .frame(minWidth: 640, minHeight: 400)
        .navigationTitle(bundle.name)
        .navigationSubtitle(running ? controller.state.label : "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if running {
                    Button { model.togglePause(bundle) } label: {
                        Label(controller.state == .paused ? "Resume" : "Pause",
                              systemImage: controller.state == .paused ? "play.fill" : "pause.fill")
                    }.help(controller.state == .paused ? "Resume" : "Pause")
                    Button { model.toggleCoherence(bundle) } label: {
                        Label("Seamless", systemImage: "square.on.square")
                    }
                    .help("Seamless mode: show the VM's apps as Mac windows (⌃⌘C)")
                    .disabled(controller.agent?.guestHello == nil || !controller.config.features.coherence)
                    Menu {
                        Button("Suspend") { model.suspend(bundle) }
                        Button("Shut Down") { model.stop(bundle) }
                        Button("Restart") { model.restart(bundle) }
                        Divider()
                        Button("Force Stop", role: .destructive) { model.stop(bundle, force: true) }
                    } label: { Label("Power", systemImage: "power") }
                    .help("Suspend, shut down or restart")
                    Menu {
                        USBMenuItems(bundle: bundle, controller: controller)
                    } label: { Label("USB", systemImage: "cable.connector") }
                    .help("Connect USB devices and drives")
                }
                Button { model.configTab = .general; openWindow(id: "config", value: bundle.url.path) } label: {
                    Label("Configure", systemImage: "gearshape")
                }.help("Configure")
            }
        }
    }
}

private struct IdleScreen: View {
    @EnvironmentObject var model: AppModel
    let bundle: VMBundle
    @ObservedObject var controller: VirtualMachineController

    var body: some View {
        VStack(spacing: 16) {
            switch controller.state {
            case .starting, .stopping, .suspending:
                ProgressView().controlSize(.large).tint(.white)
                Text(controller.state.label).font(.title3)
            default:
                Button { model.start(bundle) } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 38))
                        .frame(width: 96, height: 96)
                        .background(Circle().fill(.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .help(controller.state == .suspended ? "Resume" : "Start")
                Text(controller.state == .suspended ? "Suspended — click to resume" : "\(bundle.name) is shut down")
                    .font(.title3)
                if let e = controller.lastError {
                    Text(e).font(.callout).foregroundStyle(.red.opacity(0.9)).frame(maxWidth: 440).multilineTextAlignment(.center)
                }
            }
        }
        .foregroundStyle(.white)
    }
}

/// Shown while a macOS guest's agent may not record the screen or control the computer. The agent
/// asks for that only when the user wants it to, so the window offers the request where it's seen.
private struct AgentPermissionBanner: View {
    @EnvironmentObject var model: AppModel
    let bundle: VMBundle
    @ObservedObject var controller: VirtualMachineController
    let hide: () -> Void
    @State private var asked = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            Group {
                if controller.agent?.guestHello?.capabilities.contains("permissions") != true {
                    Text("Update Vitrine Agent so it can ask for the permissions seamless mode needs.")
                } else if asked {
                    Text("Allow Vitrine Agent in both prompts in the VM. It then restarts by itself to use them.")
                } else {
                    Text("Seamless mode needs Vitrine Agent to record the screen and control the computer inside the VM.")
                }
            }
            .font(.callout).lineLimit(2)
            Spacer(minLength: 8)
            if controller.agent?.guestHello?.capabilities.contains("permissions") != true {
                Button("Install Vitrine Agent") { model.installAgent(bundle) }
            } else {
                Button(asked ? "Ask Again" : "Allow…") { asked = controller.requestAgentPermissions() }
                    .buttonStyle(.borderedProminent)
            }
            Button(action: hide) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Hide")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.bar)
    }
}

private struct PausedOverlay: View {
    let resume: () -> Void
    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
            Button(action: resume) {
                Image(systemName: "play.fill").font(.system(size: 34))
                    .frame(width: 86, height: 86).background(Circle().fill(.white.opacity(0.2)))
            }
            .buttonStyle(.plain).foregroundStyle(.white).help("Resume")
        }
    }
}

struct VMDisplayView: NSViewRepresentable {
    let virtualMachine: VZVirtualMachine
    let autoResize: Bool
    var swapCommandOption = false
    var onDrop: ([URL]) -> Void = { _ in }

    func makeNSView(context: Context) -> FileDropContainer<GuestDisplayView> {
        let v = GuestDisplayView()
        v.swapCommandOption = swapCommandOption
        v.capturesSystemKeys = true
        v.automaticallyReconfiguresDisplay = autoResize
        v.virtualMachine = virtualMachine
        let container = FileDropContainer(content: v, onDrop: onDrop)
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        if ProcessInfo.processInfo.environment["VITRINE_DEBUG_LAYERS"] == "1" {
            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                FileHandle.standardError.write(Data(("=== layers\n" + LayerInspector.describe(view: v)).utf8))
            }
        }
        return container
    }

    func updateNSView(_ c: FileDropContainer<GuestDisplayView>, context: Context) {
        let v = c.content
        v.swapCommandOption = swapCommandOption
        if v.virtualMachine !== virtualMachine { v.virtualMachine = virtualMachine }
        v.automaticallyReconfiguresDisplay = autoResize
        c.onDrop = onDrop
    }
}

/// Hosts a display view and accepts files dragged from Finder (drag and drop).
final class FileDropContainer<Content: NSView>: NSView {
    let content: Content
    var onDrop: ([URL]) -> Void
    private let highlight = CALayer()

    init(content: Content, onDrop: @escaping ([URL]) -> Void) {
        self.content = content
        self.onDrop = onDrop
        super.init(frame: .zero)
        wantsLayer = true
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        registerForDraggedTypes([.fileURL])
        highlight.borderColor = NSColor.controlAccentColor.cgColor
        highlight.borderWidth = 0
        layer?.addSublayer(highlight)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        content.frame = bounds
        highlight.frame = bounds
    }

    private func urls(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !urls(sender).isEmpty else { return [] }
        highlight.borderWidth = 4
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlight.borderWidth = 0 }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlight.borderWidth = 0
        let files = urls(sender)
        guard !files.isEmpty else { return false }
        onDrop(files)
        return true
    }
}

struct QEMUDisplayRepresentable: NSViewRepresentable {
    let rfb: RFBClient
    var swapCommandOption = false
    var pixelPerfect = false
    func makeNSView(context: Context) -> QEMUDisplayView {
        let v = QEMUDisplayView(rfb: rfb)
        updateNSView(v, context: context)
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }
    func updateNSView(_ v: QEMUDisplayView, context: Context) {
        v.swapCommandOption = swapCommandOption
        if v.pixelPerfect != pixelPerfect { v.pixelPerfect = pixelPerfect }
    }
}

/// Hands the hosting NSWindow to a closure once the view is in a window (called once).
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    final class Coordinator { var done = false }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            if let w = v.window, !context.coordinator.done { context.coordinator.done = true; onWindow(w) }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
