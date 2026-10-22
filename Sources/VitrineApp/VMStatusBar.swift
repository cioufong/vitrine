import SwiftUI
import VitrineAgentProtocol
import VitrineCore
import VitrineVZ

/// The strip under a running VM's display: what the guest is doing, and switches for the things
/// that can change without restarting it.
struct VMStatusBar: View {
    /// View ▸ Show Status Bar, for all VM windows.
    static let visibilityKey = "showVMStatusBar"

    @EnvironmentObject var model: AppModel
    let bundle: VMBundle
    @ObservedObject var controller: VirtualMachineController
    @State private var guestIP: String?
    @State private var cableBusy = false

    private var config: VMConfig { controller.config }

    var body: some View {
        HStack(spacing: 14) {
            stateItem
            agentItem
            if let ip = guestIP, !controller.networkCableDisconnected {
                Button { copy(ip) } label: { Label(ip, systemImage: "network") }
                    .help("IP address — click to copy")
            }
            if let s = controller.guestStats {
                statsItems(s)
            }
            Spacer(minLength: 8)
            toggles
        }
        .buttonStyle(.plain)
        .labelStyle(StatusLabelStyle())
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .task(id: "\(config.network.mode)-\(controller.agentConnection)") {
            // The lookup may probe the network; keep it off the main thread and refresh now and then.
            while !Task.isCancelled {
                let b = bundle, c = config
                guestIP = await Task.detached { b.guestIPAddress(c) }.value
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    // MARK: Status

    private var stateItem: some View {
        HStack(spacing: 5) {
            Circle().fill(controller.state == .paused ? Color.orange : Color.green).frame(width: 7, height: 7)
            Text(controller.state.label)
            if let uptime = controller.guestStats?.uptimeSeconds {
                Text(Self.duration(uptime)).monospacedDigit().help("Time since the guest booted")
            } else if let since = controller.runningSince, controller.state == .running {
                Text(since, style: .timer).monospacedDigit().help("Time since the VM started")
            }
        }
    }

    @ViewBuilder private var agentItem: some View {
        switch controller.agentConnection {
        case .connected(let os, let version):
            Label(Self.shortOSName(os), systemImage: "checkmark.seal")
                .layoutPriority(-1) // the first thing to give way when the window is narrow
                .help("\(os) — Vitrine agent \(version)")
        case .connecting:
            Label("Agent connecting…", systemImage: "ellipsis.circle")
        case .notConnected, .disconnected:
            Button { model.installAgent(bundle) } label: { Label("No agent", systemImage: "exclamationmark.circle") }
                .help("Install the Vitrine agent for clipboard, seamless windows and CPU, memory and disk use")
                .disabled(controller.state != .running)
        }
    }

    @ViewBuilder private func statsItems(_ s: GuestStats) -> some View {
        if let cpu = s.cpuPercent {
            HStack(spacing: 4) {
                Text("CPU")
                Gauge(value: min(cpu, 100), in: 0...100) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity).frame(width: 36).tint(Self.tint(cpu / 100))
                Text("\(Int(cpu.rounded()))%").monospacedDigit().frame(minWidth: 26, alignment: .leading)
            }
            .fixedSize()
            .help("Guest CPU use, all cores")
        }
        if let used = s.memoryUsed, let total = s.memoryTotal, total > 0 {
            HStack(spacing: 4) {
                Text("Memory")
                Gauge(value: Double(used), in: 0...Double(total)) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity).frame(width: 36).tint(Self.tint(Double(used) / Double(total)))
                Text("\(Self.bytes(used, .memory)) / \(Self.bytes(total, .memory))").monospacedDigit()
            }
            .fixedSize()
            .help("Memory the guest uses")
        }
        if let used = s.diskUsed, let total = s.diskTotal, total > 0 {
            Label("\(Self.bytes(used, .file)) / \(Self.bytes(total, .file))", systemImage: "internaldrive")
                .monospacedDigit()
                .fixedSize()
                .help("Space used on the guest's system disk")
        }
    }

    // MARK: Switches

    private var toggles: some View {
        HStack(spacing: 2) {
            if config.network.isConnected {
                StatusToggle(label: "Network", isOn: !controller.networkCableDisconnected,
                             on: "network", off: "network.slash",
                             help: controller.networkCableDisconnected
                                ? "Network cable unplugged — click to plug it back in"
                                : "Network connected — click to unplug the cable") {
                    setCable(connected: controller.networkCableDisconnected)
                }
                .disabled(cableBusy || controller.state != .running)
            }
            StatusToggle(label: "Clipboard sharing", isOn: config.features.clipboard, on: "doc.on.clipboard.fill", off: "doc.on.clipboard",
                         help: config.features.clipboard ? "Clipboard shared — click to stop sharing" : "Clipboard not shared — click to share") {
                do { try controller.setClipboardSharing(!config.features.clipboard) } catch { model.report(error) }
            }
            if controller.guestTakesCamera || controller.cameraSharing != .off {
                CameraSwitch(controller: controller)
            }
            if controller.guestTakesBluetooth || controller.bluetoothSharing != .off {
                BluetoothSwitch(controller: controller)
            }
            if controller.qemu == nil, config.guestOS != .windows {
                StatusToggle(label: "Resize display with window", isOn: config.display.autoResize,
                             on: "arrow.up.left.and.arrow.down.right", off: "arrow.up.left.and.arrow.down.right",
                             help: config.display.autoResize ? "Display follows the window size — click to keep it fixed"
                                                             : "Display size fixed — click to follow the window") {
                    var c = config
                    c.display.autoResize.toggle()
                    do { try controller.saveConfig(c) } catch { model.report(error) }
                }
            }
            Menu {
                USBMenuItems(bundle: bundle, controller: controller)
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "cable.connector")
                    if !controller.usbAttachments.isEmpty { Text("\(controller.usbAttachments.count)").monospacedDigit() }
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(controller.usbAttachments.isEmpty ? Color.secondary : Color.accentColor)
            .accessibilityLabel(Text("USB"))
            .help("USB devices and drives")
        }
    }

    private func setCable(connected: Bool) {
        cableBusy = true
        Task {
            do { try await controller.setNetworkCable(connected: connected) } catch { model.report(error) }
            cableBusy = false
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Formatting

    static func bytes(_ n: UInt64, _ style: ByteCountFormatter.CountStyle) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: style)
    }

    /// "3 d 4 h", "2 h 05 m", "12 m".
    static func duration(_ seconds: UInt64) -> String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = seconds >= 86_400 ? [.day, .hour] : seconds >= 3600 ? [.hour, .minute] : [.minute]
        f.zeroFormattingBehavior = .dropLeading
        return f.string(from: TimeInterval(max(seconds, 60))) ?? ""
    }

    /// "Linux Debian GNU/Linux 13 (trixie) (kernel 6.12…)" → "Debian GNU/Linux 13 (trixie)";
    /// "Windows 11 Pro 24H2 (build 26100.1)" → "Windows 11 Pro 24H2".
    static func shortOSName(_ os: String) -> String {
        var s = os
        if let r = s.range(of: #" \((kernel|build) [^)]*\)$"#, options: .regularExpression) { s.removeSubrange(r) }
        if s.hasPrefix("Linux "), s.dropFirst(6).contains("Linux") { s.removeFirst(6) }
        return s
    }

    static func tint(_ fraction: Double) -> Color {
        fraction > 0.9 ? .red : fraction > 0.7 ? .orange : .accentColor
    }
}

/// An icon that reads as on (accent colour, filled background) or off (secondary).
private struct StatusToggle: View {
    let label: LocalizedStringKey
    let isOn: Bool
    let on: String
    let off: String
    let help: LocalizedStringKey
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? on : off)
                .frame(width: 24, height: 18)
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .background(RoundedRectangle(cornerRadius: 4).fill(isOn ? Color.accentColor.opacity(0.15) : .clear))
                .opacity(isEnabled ? 1 : 0.4)
        }
        .help(help)
        .accessibilityLabel(Text(label))
        .accessibilityValue(isOn ? Text("On") : Text("Off"))
    }
}

/// Shares the Mac's camera with the guest for this run. A problem (no permission, no virtual camera
/// in the guest yet) opens a popover that says what's wrong and can install the guest's half.
private struct CameraSwitch: View {
    @ObservedObject var controller: VirtualMachineController

    var body: some View {
        ShareSwitch(sharing: controller.cameraSharing, running: controller.state == .running,
                    label: "Camera", on: "video.fill", off: "video.slash", offWithProblem: "video.badge.exclamationmark",
                    help: help, problemTitle: "The camera couldn't be shared", installTitle: "Install Camera Support",
                    set: controller.setCameraSharing, install: controller.installCameraSupport) {
            if controller.config.guestOS == .macOS {
                Text("Vitrine can move the guest's agent to /Applications over SSH, where macOS lets it add the Vitrine Camera. The guest then asks you to allow the camera extension.")
            } else if controller.config.guestOS == .windows {
                Text("Vitrine can install the Vitrine Camera (a Media Foundation virtual camera, Windows 11 only) in the guest over SSH.")
            } else {
                Text("Vitrine can install the guest's virtual camera (v4l2loopback) over SSH. This needs the guest's internet connection and takes a few minutes.")
            }
        }
    }

    private var help: LocalizedStringKey {
        switch controller.cameraSharing {
        case .on(let device): "Camera shared with the guest (\(device)) — click to stop"
        case .starting: "Starting the camera…"
        case .installing: "Installing camera support in the guest…"
        case .failed: "The camera couldn't be shared — click for details"
        case .off: "Camera not shared — click to share the Mac's camera with the guest"
        }
    }
}

/// Shares the Mac's Bluetooth LE with the guest for this run (experimental). Like the camera, a
/// problem opens a popover that can install the guest's half.
private struct BluetoothSwitch: View {
    @ObservedObject var controller: VirtualMachineController

    var body: some View {
        ShareSwitch(sharing: controller.bluetoothSharing, running: controller.state == .running,
                    label: "Bluetooth", on: "antenna.radiowaves.left.and.right",
                    off: "antenna.radiowaves.left.and.right.slash", offWithProblem: "exclamationmark.triangle",
                    help: help, problemTitle: "Bluetooth couldn't be shared", installTitle: "Install Bluetooth Support",
                    set: controller.setBluetoothSharing, install: controller.installBluetoothSupport) {
            Text("Vitrine can install BlueZ and its Bluetooth bridge in the guest over SSH. This needs the guest's internet connection.")
        }
    }

    private var help: LocalizedStringKey {
        switch controller.bluetoothSharing {
        case .on(let device): "Bluetooth shared with the guest (\(device)) — click to stop"
        case .starting: "Starting Bluetooth…"
        case .installing: "Installing Bluetooth support in the guest…"
        case .failed: "Bluetooth couldn't be shared — click for details"
        case .off: "Bluetooth not shared — click to let the guest use the Mac's Bluetooth LE (experimental)"
        }
    }
}

/// The switch of one of the Mac's devices shared with the guest (CameraSwitch, BluetoothSwitch).
/// When sharing fails it opens a popover that says why; when the guest's half is missing, the
/// popover explains (`installNote`) and offers to install it.
private struct ShareSwitch<InstallNote: View>: View {
    @EnvironmentObject var model: AppModel
    let sharing: GuestShareState
    let running: Bool
    let label: LocalizedStringKey
    let on: String
    let off: String
    let offWithProblem: String
    let help: LocalizedStringKey
    let problemTitle: LocalizedStringKey
    let installTitle: LocalizedStringKey
    let set: (Bool) async -> Void
    let install: () async throws -> Void
    @ViewBuilder let installNote: InstallNote
    @State private var showProblem = false

    var body: some View {
        StatusToggle(label: label, isOn: isOn, on: on, off: problem == nil ? off : offWithProblem, help: help) {
            if problem != nil {
                showProblem = true
            } else {
                let share = !isOn
                Task { await set(share) }
            }
        }
        .disabled(busy || !running)
        .popover(isPresented: $showProblem, arrowEdge: .top) { problemView }
        .onChange(of: sharing) { _, new in
            if case .failed = new { showProblem = true }
        }
    }

    private var isOn: Bool {
        switch sharing {
        case .on, .starting: true
        default: false
        }
    }

    private var busy: Bool { sharing == .starting || sharing == .installing }

    private var problem: (message: String, guestSide: Bool)? {
        if case .failed(let m, let g) = sharing { return (m, g) }
        return nil
    }

    private var problemView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(problemTitle).font(.headline)
            Text(problem?.message ?? "").font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if problem?.guestSide == true {
                installNote.font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Close") { showProblem = false; Task { await set(false) } }
                if problem?.guestSide == true {
                    Button(installTitle) {
                        showProblem = false
                        Task {
                            do { try await install() } catch { model.report(error) }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Try Again") { showProblem = false; Task { await set(true) } }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon; configuration.title }
    }
}
