import SwiftUI
import VitrineCore
import VitrineVZ
import VitrineAgentHost

/// The compact VM list ("Control Center"): one card per VM with a hover play button
/// and a gear for configuration.
struct ControlCenterView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if model.bundles.isEmpty {
                EmptyLibraryView()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.bundles, id: \.self) { b in
                            if let c = model.controller(for: b) {
                                VMCard(bundle: b, controller: c)
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 380, idealWidth: 420, minHeight: 300, idealHeight: 460)
        .background(.background)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { openWindow(id: "assistant") } label: { Label("New", systemImage: "plus") }
                    .help("Create a new virtual machine")
            }
        }
        .navigationTitle("Control Center")
        .onAppear { model.openVMWindow = { [openWindow] path in openWindow(id: "vm", value: path) } }
    }
}

private struct EmptyLibraryView: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "macwindow.badge.plus")
                .font(.system(size: 54, weight: .thin))
                .foregroundStyle(.tint)
            Text("No virtual machines yet").font(.title3.weight(.semibold))
            Text("Vitrine downloads macOS, installs it and sets up your account for you.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 280)
            Button("Create New…") { openWindow(id: "assistant") }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct VMCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let bundle: VMBundle
    @ObservedObject var controller: VirtualMachineController
    @State private var hovering = false
    /// Another process (vitrinectl) runs this VM; Vitrine can't start it meanwhile.
    @State private var externalOwner: pid_t?

    var isIdle: Bool { [.stopped, .suspended, .error].contains(controller.state) && externalOwner == nil }

    var body: some View {
        row
            .task(id: controller.state) {
                // Poll while this process doesn't run the VM: vitrinectl may start or stop it any time.
                while !Task.isCancelled {
                    let idle = [.stopped, .suspended, .error].contains(controller.state)
                    let b = bundle
                    // lockOwner() may wait briefly for a starting process to write its pid: not on the main thread.
                    let owner = idle ? await Task.detached { b.lockOwner() }.value : nil
                    externalOwner = owner.flatMap { $0.pid == getpid() ? nil : $0.pid }
                    // An external runner may have suspended, discarded, or restored state since
                    // this controller was created. Refresh only once no process owns the bundle.
                    if idle && owner == nil { controller.refreshSavedState() }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
    }

    private var row: some View {
        HStack(spacing: 12) {
            ZStack {
                VMThumbnail(osVersion: controller.config.osVersionLabel, state: controller.state,
                            isLinux: controller.config.guestOS == .linux, isWindows: controller.config.guestOS == .windows,
                            image: NSImage(contentsOf: bundle.thumbnailURL), generation: model.thumbnailGeneration)
                if externalOwner == nil && (hovering || controller.state == .running) {
                    Button {
                        if isIdle { model.start(bundle) }
                        openWindow(id: "vm", value: bundle.url.path)
                    } label: {
                        Image(systemName: isIdle ? "play.fill" : "macwindow")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(isIdle ? "Start" : "Show window")
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(bundle.name).font(.headline).lineLimit(1)
                Text(controller.config.osVersionLabel).font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    if let pid = externalOwner {
                        Circle().fill(VirtualMachineController.RunState.running.color).frame(width: 7, height: 7)
                        Text("Running in vitrinectl").font(.caption).foregroundStyle(.secondary)
                            .help("Started from the command line (pid \(pid)). Stop it there, or with `vitrinectl stop \(bundle.name)`.")
                    } else {
                        Circle().fill(controller.state.color).frame(width: 7, height: 7)
                        Text(controller.state.label).font(.caption).foregroundStyle(.secondary)
                    }
                    if controller.agent?.guestHello != nil {
                        Image(systemName: "puzzlepiece.extension.fill").font(.caption2).foregroundStyle(.secondary)
                            .help("Vitrine Agent connected")
                    }
                }
            }
            Spacer(minLength: 0)
            Button { openWindow(id: "config", value: bundle.url.path) } label: {
                Image(systemName: "gearshape").font(.system(size: 15))
            }
            .buttonStyle(.borderless)
            .help("Configure")
            .opacity(hovering ? 1 : 0.55)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(hovering ? Color.primary.opacity(0.06) : Color.primary.opacity(0.03)))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            guard externalOwner == nil else { return }
            if isIdle { model.start(bundle) }
            openWindow(id: "vm", value: bundle.url.path)
        }
        .contextMenu { VMActionsMenu(bundle: bundle, controller: controller) }
    }
}

/// Stylised OS tile used until a live thumbnail exists.
struct VMThumbnail: View {
    let osVersion: String
    let state: VirtualMachineController.RunState
    var isLinux = false
    var isWindows = false
    var image: NSImage? = nil
    var generation = 0
    var body: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(LinearGradient(colors: [Color(red: 0.25, green: 0.36, blue: 0.85), Color(red: 0.62, green: 0.32, blue: 0.78)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .id(generation)
                } else {
                    Image(systemName: isWindows ? "pc" : (isLinux ? "terminal.fill" : "apple.logo")).font(.system(size: 22)).foregroundStyle(.white.opacity(0.9))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .bottomTrailing) {
                if state == .suspended {
                    Image(systemName: "moon.zzz.fill").font(.caption).foregroundStyle(.white).padding(4)
                }
            }
            .saturation(state == .running || state == .paused ? 1 : 0.35)
            .frame(width: 96, height: 60)
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    }
}

/// Shared VM actions for context menus and the Actions menu.
struct VMActionsMenu: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let bundle: VMBundle
    @ObservedObject var controller: VirtualMachineController

    var body: some View {
        let running = controller.state == .running || controller.state == .paused
        if running {
            Button("Show Window") { openWindow(id: "vm", value: bundle.url.path) }
            Button(controller.state == .paused ? "Resume" : "Pause") { model.togglePause(bundle) }
            Button("Suspend") { model.suspend(bundle) }
            Button("Shut Down") { model.stop(bundle) }
            Button("Restart") { model.restart(bundle) }
            Button("Force Stop") { model.stop(bundle, force: true) }
            Divider()
            Button(model.coherenceActive.contains(bundle.url.path) ? "Exit Seamless Mode" : "Enter Seamless Mode") {
                model.toggleCoherence(bundle)
            }
            Button("Install Vitrine Agent") { model.installAgent(bundle) }
            Button("Add Apps to Launchpad") { model.createLaunchers(bundle) }
                .disabled(controller.agent?.guestHello?.capabilities.contains("apps") != true)
        } else {
            Button(controller.state == .suspended ? "Resume" : "Start") {
                model.start(bundle); openWindow(id: "vm", value: bundle.url.path)
            }
            Button("Start in Recovery Mode") { model.start(bundle, recovery: true); openWindow(id: "vm", value: bundle.url.path) }
            if controller.state == .suspended { Button("Discard Suspended State") { controller.discardSavedState() } }
        }
        Divider()
        Button("Configure…") { openWindow(id: "config", value: bundle.url.path) }
        Button("Snapshots…") { model.configTab = .snapshots; openWindow(id: "config", value: bundle.url.path) }
        Button("Clone") { model.clone(bundle) }.disabled(running)
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([bundle.url]) }
        Divider()
        Button("Remove…", role: .destructive) { model.delete(bundle) }.disabled(running)
    }
}

extension VMConfig {
    var osVersionLabel: String { installedOS ?? guestOS.rawValue.capitalized }
}

extension VirtualMachineController.RunState {
    var label: String {
        switch self {
        case .stopped: return String(localized: "Stopped")
        case .starting: return String(localized: "Starting…")
        case .running: return String(localized: "Running")
        case .paused: return String(localized: "Paused")
        case .suspending: return String(localized: "Suspending…")
        case .suspended: return String(localized: "Suspended")
        case .stopping: return String(localized: "Shutting down…")
        case .error: return String(localized: "Error")
        }
    }
    var color: Color {
        switch self {
        case .running: return .green
        case .paused, .suspended, .suspending: return .orange
        case .error: return .red
        case .starting, .stopping: return .yellow
        case .stopped: return .gray
        }
    }
}
