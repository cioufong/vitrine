import SwiftUI
import VitrineCore
import VitrineVZ

enum ConfigTab: String, CaseIterable, Identifiable {
    case general = "General", options = "Options", hardware = "Hardware", snapshots = "Snapshots"
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .general: return "General"
        case .options: return "Options"
        case .hardware: return "Hardware"
        case .snapshots: return "Snapshots"
        }
    }
    var icon: String {
        switch self {
        case .general: return "info.circle"
        case .options: return "slider.horizontal.3"
        case .hardware: return "cpu"
        case .snapshots: return "clock.arrow.circlepath"
        }
    }
}

/// Per-VM configuration window with icon tabs ("Configuration").
struct ConfigurationView: View {
    @EnvironmentObject var model: AppModel
    let bundle: VMBundle

    var body: some View {
        if let c = model.controller(for: bundle) {
            ConfigurationContent(bundle: bundle, controller: c)
                .onAppear { c.reloadConfig() }
        } else {
            Text("Cannot open configuration").padding()
        }
    }
}

private struct ConfigurationContent: View {
    @EnvironmentObject var model: AppModel
    let bundle: VMBundle
    @ObservedObject var controller: VirtualMachineController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(ConfigTab.allCases) { tab in
                    Button { model.configTab = tab } label: {
                        VStack(spacing: 3) {
                            Image(systemName: tab.icon).font(.system(size: 20))
                            Text(tab.title).font(.caption)
                        }
                        .frame(width: 78, height: 50)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(model.configTab == tab ? Color.primary.opacity(0.10) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.configTab == tab ? Color.accentColor : .primary)
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)
            Divider()
            Group {
                switch model.configTab {
                case .general: GeneralPane(bundle: bundle, controller: controller)
                case .options: OptionsPane(bundle: bundle, controller: controller)
                case .hardware: HardwarePane(bundle: bundle, controller: controller)
                case .snapshots: SnapshotsPane(bundle: bundle, controller: controller)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if controller.state != .stopped && controller.state != .error && model.configTab == .hardware {
                Divider()
                Label("Some settings can't be changed while the virtual machine is running or suspended.",
                      systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary).padding(8)
            }
        }
        .frame(minWidth: 620, idealWidth: 660, minHeight: 460, idealHeight: 500)
        .navigationTitle("\(bundle.name) — Configuration")
    }
}

// MARK: - Panes

private struct GeneralPane: View {
    @EnvironmentObject var model: AppModel
    let bundle: VMBundle
    @ObservedObject var controller: VirtualMachineController
    @State private var notes = ""

    var body: some View {
        Form {
            LabeledContent("Name", value: bundle.name)
            LabeledContent("OS", value: controller.config.osVersionLabel)
            if let acct = controller.config.account {
                LabeledContent("Account", value: "\(acct.fullName) (\(acct.username))")
            }
            LabeledContent("Location") {
                Button(bundle.url.path) { NSWorkspace.shared.activateFileViewerSelecting([bundle.url]) }
                    .buttonStyle(.link).lineLimit(1).truncationMode(.middle)
            }
            LabeledContent("Disk usage", value: formatBytes(controller.config.disks.reduce(0) {
                $0 + DiskImage.allocatedSize(of: bundle.resolve($1.path))
            }))
            Section("Notes") {
                TextEditor(text: $notes).frame(minHeight: 80).font(.body)
                    .onChange(of: notes) { save { $0.notes = notes } }
            }
        }
        .formStyle(.grouped)
        .onAppear { notes = controller.config.notes }
    }

    func save(_ change: (inout VMConfig) -> Void) {
        var c = controller.config; change(&c)
        do { try controller.saveConfig(c) } catch { model.report(error) }
    }
}

private struct OptionsPane: View {
    @EnvironmentObject var model: AppModel
    let bundle: VMBundle
    @ObservedObject var controller: VirtualMachineController

    var body: some View {
        Form {
            Section("Startup and Shutdown") {
                Toggle("Start when Vitrine opens", isOn: binding(\.features.startWithVitrine))
                Picker("When window is closed", selection: binding(\.features.closeAction)) {
                    Text("Suspend").tag(VMConfig.CloseAction.suspend)
                    Text("Shut down").tag(VMConfig.CloseAction.shutDown)
                    Text("Keep running in background").tag(VMConfig.CloseAction.keepRunning)
                    Text("Ask what to do").tag(VMConfig.CloseAction.ask)
                }
                Toggle("Disposable: discard all changes when the VM stops", isOn: binding(\.features.disposable))
                if controller.config.features.disposable {
                    Text("Each run starts from the state the VM had when it was last started in this mode. Disks, settings and firmware variables revert; shared folders on the Mac are not affected. Disposable VMs shut down instead of suspending.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Sharing") {
                Toggle("Share clipboard", isOn: binding(\.features.clipboard))
                SharedFoldersEditor(controller: controller)
            }
            Section("Applications") {
                Toggle("Allow seamless mode (show guest windows on the Mac desktop)", isOn: binding(\.features.coherence))
                LabeledContent("Vitrine Agent", value: controller.agentConnection.localizedDescription)
                Button("Install Vitrine Agent") { model.installAgent(bundle) }
                    .disabled(controller.state != .running || controller.config.account == nil)
            }
            if controller.config.guestOS != .macOS { // macOS guests set their clock themselves (network time)
                Section("Date & Time") {
                    Toggle("Sync guest clock and time zone with this Mac", isOn: binding(\.features.timeSync))
                    Text("Applied whenever the Vitrine Agent connects (after starting or resuming).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    func binding<T>(_ kp: WritableKeyPath<VMConfig, T>) -> Binding<T> {
        Binding(get: { controller.config[keyPath: kp] }, set: { v in
            var c = controller.config; c[keyPath: kp] = v
            do { try controller.saveConfig(c) } catch { model.report(error) }
        })
    }
}

struct SharedFoldersEditor: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var controller: VirtualMachineController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Shared folders").font(.subheadline.weight(.medium))
            if controller.config.shares.isEmpty {
                Text("None").foregroundStyle(.secondary).font(.callout)
            }
            ForEach(controller.config.shares) { share in
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(share.name)
                        Text(share.hostPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Toggle("Read-only", isOn: Binding(get: { share.readOnly }, set: { ro in
                        update { shares in if let i = shares.firstIndex(of: share) { shares[i].readOnly = ro } }
                    })).toggleStyle(.checkbox).font(.caption)
                    Button { update { $0.removeAll { $0.name == share.name } } } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Add Folder…", action: add)
                Spacer()
                Text(guestLocation).font(.caption).foregroundStyle(.secondary)
            }
            if usesNineP && !controller.config.shares.isEmpty {
                Text("Mount in the guest (as root); changes take effect when the VM next starts:")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(controller.config.shares) { share in
                    Text("mkdir -p /mnt/\(share.mountTag) && mount -t 9p -o trans=virtio,version=9p2000.L\(share.readOnly ? ",ro" : "") \(share.mountTag) /mnt/\(share.mountTag)")
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
    }

    /// QEMU Linux guests get one virtio-9p export per folder (QEMUArguments).
    var usesNineP: Bool { controller.config.effectiveBackend == .qemu && controller.config.guestOS != .windows }

    var guestLocation: String {
        switch (controller.config.guestOS, controller.config.effectiveBackend) {
        case (.macOS, _): String(localized: "Guest path: /Volumes/My Shared Files")
        case (.windows, _): String(localized: "Guest: network drives from Z: down")
        case (_, .vz): String(localized: "Guest path: /mnt/vitrine/<folder>")
        case (_, .qemu): String(localized: "Guest: virtio-9p, one mount tag per folder")
        }
    }

    func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        update { shares in
            for url in panel.urls {
                var name = url.lastPathComponent, n = 2
                while shares.contains(where: { $0.name == name }) { name = "\(url.lastPathComponent) \(n)"; n += 1 }
                shares.append(.init(hostPath: url.path, name: name))
            }
        }
    }

    func update(_ change: (inout [VMConfig.SharedDirectory]) -> Void) {
        var shares = controller.config.shares
        change(&shares)
        do { try controller.updateShares(shares) } catch { model.report(error) }
    }
}

private struct HardwarePane: View {
    enum Item: String, CaseIterable, Identifiable {
        case cpu = "CPU & Memory", graphics = "Graphics", input = "Mouse & Keyboard", sound = "Sound & Camera",
             usb = "USB & Bluetooth", network = "Network", disk = "Hard Disk"
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .cpu: return "CPU & Memory"
            case .graphics: return "Graphics"
            case .input: return "Mouse & Keyboard"
            case .sound: return "Sound & Camera"
            case .usb: return "USB & Bluetooth"
            case .network: return "Network"
            case .disk: return "Hard Disk"
            }
        }
        var icon: String {
            switch self {
            case .cpu: return "cpu"
            case .graphics: return "display"
            case .input: return "keyboard"
            case .sound: return "speaker.wave.2"
            case .usb: return "cable.connector"
            case .network: return "network"
            case .disk: return "internaldrive"
            }
        }
        /// Settings of these items apply to the running VM too.
        var isLive: Bool { self == .usb }
    }

    @EnvironmentObject var model: AppModel
    let bundle: VMBundle
    @ObservedObject var controller: VirtualMachineController
    @State private var item: Item = .cpu
    /// Another process (vitrinectl) runs the VM: its settings are as locked as if it ran here.
    @State private var runsElsewhere = false

    var locked: Bool { runsElsewhere || (controller.state != .stopped && controller.state != .error) }

    var body: some View {
        HStack(spacing: 0) {
            List(Item.allCases, selection: $item) { i in
                Label(i.title, systemImage: i.icon).tag(i)
            }
            .listStyle(.sidebar)
            .frame(width: 190)
            Divider()
            Form { detail }.formStyle(.grouped).disabled(locked && !item.isLive)
        }
        .task(id: controller.state) {
            let b = bundle
            while !Task.isCancelled {
                let owner = await Task.detached { b.lockOwner() }.value
                runsElsewhere = owner.map { $0.pid != getpid() } ?? false
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    @ViewBuilder var detail: some View {
        let host = ProcessInfo.processInfo
        switch item {
        case .cpu:
            if controller.config.guestOS == .linux && controller.config.effectiveBackend == .vz {
                Section("Rosetta") {
                    Toggle("Run x86_64 Linux binaries with Rosetta", isOn: binding(\.features.rosetta))
                }
            }
            if controller.config.effectiveBackend == .qemu && controller.config.effectiveArchitecture == .x86_64 {
                Section("Boot security") {
                    Toggle("Secure Boot with Microsoft keys", isOn: binding(\.features.secureBoot))
                    Text("The firmware only starts loaders signed by Microsoft (Windows, and Linux through its signed shim). Changing this resets the VM's UEFI variables when it next starts.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if controller.config.guestOS == .linux && controller.config.effectiveBackend == .vz {
                Section("Nested virtualization") {
                    Toggle("Allow this VM to run its own VMs (KVM)", isOn: binding(\.features.nestedVirtualization))
                        .disabled(!ConfigurationBuilder.nestedVirtualizationSupported && !controller.config.features.nestedVirtualization)
                    if !ConfigurationBuilder.nestedVirtualizationSupported {
                        Text("Needs a Mac with an M3 chip or later and macOS 15 or later.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Processors") {
                ValueSlider("CPUs", selection: binding(\.cpuCount), values: Array(1...host.processorCount)) { "\($0)" }
                Text("Your Mac has \(host.processorCount) cores.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Memory") {
                ValueSlider("Memory", selection: binding(\.memoryMiB),
                            values: (2...max(2, Int(host.physicalMemory >> 30))).map { UInt64($0) << 10 }) { mib in
                    // `vitrinectl set --memory` can configure sizes between whole GiB (3584M).
                    mib % 1024 == 0 ? String(localized: "\(Int(mib >> 10)) GB")
                        : String(localized: "\((Double(mib) / 1024).formatted(.number.precision(.fractionLength(1)))) GB")
                }
                Text("Your Mac has \(host.physicalMemory >> 30) GB.").font(.caption).foregroundStyle(.secondary)
                if controller.config.memoryMiB << 20 > host.physicalMemory / 4 * 3 {
                    Text("Leaving less than a quarter of the Mac's memory to macOS can make both slow.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        case .graphics:
            Section("Display") {
                Picker("Resolution", selection: Binding(get: { "\(controller.config.display.widthPixels)x\(controller.config.display.heightPixels)" },
                                                       set: { setResolution($0) })) {
                    if let s = NSScreen.main {
                        let px = CoherenceDisplay.pixels(for: s)
                        Text("Best for this display (\(px.width)×\(px.height))").tag("\(px.width)x\(px.height)")
                    }
                    ForEach(resolutionChoices, id: \.self) {
                        Text($0.replacingOccurrences(of: "x", with: "×")).tag($0)
                    }
                }
                Toggle("Resize guest display with window", isOn: binding(\.display.autoResize))
                if controller.config.effectiveBackend == .qemu {
                    Picker("Scaling", selection: binding(\.features.pixelPerfectScaling)) {
                        Text("Smooth").tag(false)
                        Text("Sharp pixels").tag(true)
                    }
                }
                LabeledContent("Acceleration", value: controller.config.guestOS == .macOS
                               ? "Paravirtualized Metal (Apple GPU)" : "virtio-gpu 2D (3D via QEMU backend — roadmap)")
            }
        case .input:
            Section("Pointing") {
                if controller.config.guestOS == .macOS {
                    LabeledContent("Trackpad") { Text("Mac trackpad (gestures supported)") }
                    LabeledContent("Keyboard") { Text("Mac keyboard (Globe/Fn supported)") }
                } else {
                    LabeledContent("Pointer") { Text("USB tablet (follows your Mac pointer)") }
                    LabeledContent("Keyboard") { Text("USB keyboard") }
                }
            }
            Section("Keyboard") {
                Toggle("Swap ⌘ Command and ⌥ Option", isOn: binding(\.features.swapCommandOption))
                Text("Puts the guest's Alt key under your thumb, where Windows and Linux expect it. Use Actions ▸ Send Key for combinations the Mac keeps for itself, such as Ctrl+Alt+Delete.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .sound:
            Section("Sound") {
                Toggle("Sound output", isOn: binding(\.features.sound))
                Toggle("Microphone", isOn: binding(\.features.microphone))
                    .disabled(!controller.config.features.sound)
                Text(controller.config.features.microphone && controller.config.features.sound
                     ? "The guest can record from the Mac's current input device (macOS asks for permission the first time)."
                     : "The guest gets no audio input; Vitrine never opens the Mac's microphone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Camera") {
                LabeledContent("Camera") {
                    Text(controller.config.guestOS == .windows ? "Not available" : "Shared from the VM window")
                }
                Group {
                    switch controller.config.guestOS {
                    case .linux:
                        Text("Linux guests with the Vitrine agent get the Mac's camera as a webcam (a v4l2loopback device) while you turn it on with the camera switch in the VM window's status bar. Vitrine installs the guest's half the first time. The camera is never shared at startup.")
                    case .macOS:
                        Text("macOS guests get the Mac's camera as “Vitrine Camera” while the camera switch in the VM window's status bar is on. The camera extension inside the Vitrine agent must be signed by an Apple Developer team before macOS activates it (docs/signing.md).")
                    case .windows:
                        Text("Virtualization.framework and QEMU have no virtual camera to give this guest. An external USB webcam can be connected under USB & Bluetooth where USB passthrough is available.")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        case .usb:
            Section("New USB devices") {
                Picker("When a USB device is connected", selection: binding(\.features.usbConnect)) {
                    Text("Ask what to do").tag(VMConfig.USBConnectPolicy.ask)
                    Text("Connect to this VM").tag(VMConfig.USBConnectPolicy.connect)
                    Text("Keep it on the Mac").tag(VMConfig.USBConnectPolicy.keepOnMac)
                }
                Text("Applies while this VM is running and its window is in front. Devices can always be connected or disconnected from Devices → USB.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Connected now") {
                if controller.usbAttachments.isEmpty {
                    Text("Nothing is connected to this VM.").foregroundStyle(.secondary)
                }
                ForEach(controller.usbAttachments) { a in
                    HStack {
                        Label(a.attachment.localizedLabel, systemImage: { if case .image = a.attachment { return "externaldrive" } else { return "cable.connector" } }())
                        Spacer()
                        Button("Disconnect") { model.detachUSB(bundle, id: a.id) }
                    }
                }
            }
            Section("Bluetooth") {
                LabeledContent("Bluetooth") { Text("Shared through the Mac") }
                Text("Virtualization.framework and QEMU on Apple silicon have no Bluetooth controller to give a VM. Bluetooth keyboards, mice, trackpads and headphones paired with the Mac work in the VM through the Mac's input and sound.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .network:
            NetworkAdapterSection(controller: controller)
            if controller.config.network.isConnected {
                PortForwardsEditor(controller: controller)
            }
        case .disk:
            if let media = controller.config.installMedia {
                Section("Installer (USB)") {
                    LabeledContent("Image", value: URL(fileURLWithPath: media).lastPathComponent)
                    Button("Eject Installer") {
                        var c = controller.config; c.installMedia = nil
                        do { try controller.saveConfig(c) } catch { model.report(error) }
                    }
                    Text("Eject after installing so the VM boots from its own disk.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if controller.config.guestOS == .linux {
                Section("Shared folders in Linux") {
                    Text("sudo mount -t virtiofs vitrine /mnt/vitrine").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    if controller.config.features.rosetta {
                        Text("Rosetta: sudo mount -t virtiofs rosetta /media/rosetta").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            DiskCapacitySection(controller: controller)
            ForEach(controller.config.disks, id: \.path) { d in
                Section(d.path) {
                    let url = bundle.resolve(d.path)
                    LabeledContent("Format", value: DiskImage.format(of: url) == .asif ? "Apple Sparse Image (ASIF)" : "Raw (sparse)")
                    LabeledContent("Size on disk", value: formatBytes(DiskImage.allocatedSize(of: url)))
                    LabeledContent("Interface", value: d.interface.rawValue.uppercased())
                }
            }
        }
    }

    /// The presets, plus the VM's own size when it is none of them (an imported VM or a resized
    /// window), so the picker never shows a blank selection. The display's best size has its own row.
    var resolutionChoices: [String] {
        let current = "\(controller.config.display.widthPixels)x\(controller.config.display.heightPixels)"
        let best = NSScreen.main.map { s -> String in let px = CoherenceDisplay.pixels(for: s); return "\(px.width)x\(px.height)" }
        var list: [String] = ["1920x1080", "2560x1440", "2560x1600", "2880x1800", "3024x1964", "3456x2234", "3840x2160", "5120x2880"]
            .filter { $0 != best }
        if current != best, !list.contains(current) { list.insert(current, at: 0) }
        return list
    }

    func setResolution(_ s: String) {
        let parts = s.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else { return }
        var c = controller.config
        c.display.widthPixels = parts[0]; c.display.heightPixels = parts[1]
        do { try controller.saveConfig(c) } catch { model.report(error) }
    }

    func binding<T>(_ kp: WritableKeyPath<VMConfig, T>) -> Binding<T> {
        Binding(get: { controller.config[keyPath: kp] }, set: { v in
            var c = controller.config; c[keyPath: kp] = v
            do { try controller.saveConfig(c) } catch { model.report(error) }
        })
    }
}

private struct SnapshotsPane: View {
    @EnvironmentObject var model: AppModel
    let bundle: VMBundle
    @ObservedObject var controller: VirtualMachineController
    @State private var snapshots: [Snapshot] = []
    @State private var selection: UUID?
    @State private var newName = ""
    @State private var confirmRestore: Snapshot?

    var canModify: Bool { controller.state == .stopped || controller.state == .suspended || controller.state == .error }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                HStack {
                    Image(systemName: "circle.fill").foregroundStyle(.green).font(.caption)
                    Text("Current State").font(.headline)
                    Spacer()
                    Text(controller.state.label).foregroundStyle(.secondary)
                }
                ForEach(snapshots.reversed()) { s in
                    HStack(spacing: 10) {
                        Image(systemName: s.includesMemory ? "memorychip.fill" : "camera.fill")
                            .foregroundStyle(.tint).frame(width: 20)
                        VStack(alignment: .leading) {
                            Text(s.name)
                            Text(s.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if s.includesMemory { Text("with memory").font(.caption).foregroundStyle(.secondary) }
                    }
                    .tag(s.id)
                    .contextMenu {
                        Button("Go to Snapshot…") { confirmRestore = s }.disabled(!canModify)
                        Button("Delete", role: .destructive) { delete(s) }
                    }
                }
            }
            Divider()
            HStack {
                TextField("New snapshot name", text: $newName).frame(maxWidth: 220)
                Button("Take Snapshot") { take() }
                    .disabled(!canModify || newName.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button("Go To") { confirmRestore = snapshots.first { $0.id == selection } }
                    .disabled(!canModify || selection == nil)
                Button("Delete") { if let s = snapshots.first(where: { $0.id == selection }) { delete(s) } }
                    .disabled(selection == nil)
            }
            .padding(10)
            if !canModify {
                Text("Shut down or suspend the VM to take or restore snapshots. Suspended snapshots include memory and resume instantly.")
                    .font(.caption).foregroundStyle(.secondary).padding([.horizontal, .bottom], 10)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: controller.state) { reload() }
        .confirmationDialog("Go to “\(confirmRestore?.name ?? "")”?", isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } })) {
            Button("Go to Snapshot", role: .destructive) { if let s = confirmRestore { restore(s) } }
        } message: {
            Text("The current state of the virtual machine will be lost. Take a snapshot first to keep it.")
        }
    }

    func reload() { snapshots = SnapshotStore(bundle: bundle).list() }

    func take() {
        do { _ = try SnapshotStore(bundle: bundle).create(name: newName.trimmingCharacters(in: .whitespaces)); newName = ""; reload() }
        catch { model.report(error, "Snapshot failed") }
    }

    func restore(_ s: Snapshot) {
        do {
            try SnapshotStore(bundle: bundle).restore(s.id)
            if let fresh = try? bundle.loadConfig() { try? controller.saveConfig(fresh) }
            controller.refreshSavedState()
            reload()
        } catch { model.report(error, "Restore failed") }
    }

    func delete(_ s: Snapshot) {
        do { try SnapshotStore(bundle: bundle).delete(s.id); reload() } catch { model.report(error) }
    }
}

/// Shows the system disk's capacity and grows it (Linux and Windows guests).
private struct DiskCapacitySection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var controller: VirtualMachineController
    @State private var capacity: UInt64?
    @State private var target: UInt64 = 0

    private static let gib: UInt64 = 1 << 30
    private var choices: [UInt64] {
        let current = capacity ?? 0
        return [32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024].map { $0 * Self.gib }.filter { $0 > current }
    }

    var body: some View {
        Section("Capacity") {
            LabeledContent("System disk", value: capacity.map(formatBytes) ?? "—")
            if let reason = controller.diskGrowBlocker {
                Text(reason.localizedMessage).font(.caption).foregroundStyle(.secondary)
            } else if !choices.isEmpty && target != 0 {
                ValueSlider("Increase to", selection: $target, values: choices, format: formatBytes)
                Button("Increase Disk Size") {
                    do {
                        try controller.growSystemDisk(to: target)
                        capacity = target
                        target = choices.first ?? 0
                    } catch { model.report(error, "Could not grow the disk") }
                }
                .disabled(target == 0)
                Text("The disk image only uses the space the guest actually writes. The guest's partition is extended automatically the next time it starts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if controller.config.pendingDiskGrow == true {
                Label("The guest's partition will be extended on next start", systemImage: "clock")
                    .font(.caption)
            }
        }
        .task(id: controller.state) {
            capacity = await controller.loadSystemDiskCapacity()
            target = choices.first ?? 0
        }
    }
}

extension VirtualMachineController.DiskGrowBlocker {
    var localizedMessage: String {
        switch self {
        case .macOSGuest: String(localized: "macOS keeps its Recovery partition behind the system container, so the container can't take extra space. Create the VM with a larger disk instead.")
        case .running: String(localized: "Shut the VM down first.")
        case .inUse(let pid): String(localized: "The VM is in use by another process (pid \(pid)).")
        case .suspended: String(localized: "The VM is suspended: start it and shut it down (a saved state expects the current disk size).")
        }
    }
}

extension USBAttachment {
    /// `label` with the read-only note translated; `label` itself stays English for the CLI and logs.
    var localizedLabel: String {
        switch self {
        case .image(let path, true): String(localized: "\((path as NSString).lastPathComponent) (read-only)")
        default: label
        }
    }
}

extension VirtualMachineController.AgentConnection {
    var localizedDescription: String {
        switch self {
        case .notConnected: String(localized: "Not connected")
        case .connecting: String(localized: "Connecting…")
        case .connected(let os, let version): String(localized: "Connected (\(os), agent \(version))")
        case .disconnected(nil): String(localized: "Disconnected")
        case .disconnected(let reason?): String(localized: "Disconnected: \(reason)")
        }
    }
}
