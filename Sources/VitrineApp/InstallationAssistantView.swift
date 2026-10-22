import SwiftUI
import UniformTypeIdentifiers
import VitrineCore
import VitrineVZ
import VitrineQEMU

/// Installation Assistant: choose a source tile, name the VM and account, then
/// download + install with a big progress page.
struct InstallationAssistantView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    enum Source: Equatable { case latestMacOS, ipswFile(URL), linuxISO(URL), cloud(CloudImageInstaller.Distro), windowsISO(URL, VMConfig.Architecture) }
    enum Step: Equatable { case chooseSource, details, working, failed(String) }

    @State private var step: Step = .chooseSource
    @State private var source: Source = .latestMacOS
    @State private var latest: RestoreImages.Info?
    @State private var name = "macOS"
    /// Starting point for the processor stepper; compared against to tell "user left it alone".
    static let defaultCPUs = max(2, ProcessInfo.processInfo.processorCount / 2)
    @State private var cpus = InstallationAssistantView.defaultCPUs
    @State private var memoryGB = 8
    @State private var diskGB = 80
    @State private var fullName = NSFullUserName()
    @State private var username = NSUserName()
    @State private var password = ""
    @State private var customize = false
    @State private var progress: Double = 0
    @State private var phase = ""
    @State private var detail = ""
    @State private var task: Task<Void, Never>?

    private var provisioningAvailable: Bool { if #available(macOS 27, *) { return true } else { return false } }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .chooseSource: chooseSource
                case .details: details
                case .working: working
                case .failed(let msg): failed(msg)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 720, height: 520)
        .navigationTitle("Installation Assistant")
        .task { if latest == nil { latest = try? await RestoreImages.latestSupported() } }
    }

    // MARK: Step 1 — source tiles

    var chooseSource: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Create New").font(.largeTitle.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                SourceTile(icon: "apple.logo", title: String(localized: "Download macOS"),
                           subtitle: latest.map { "macOS \($0.osVersion) · \($0.buildVersion)" } ?? String(localized: "Latest version from Apple"),
                           badge: String(localized: "Recommended"), selected: source == .latestMacOS) {
                    source = .latestMacOS
                }
                SourceTile(icon: "doc.zipper", title: String(localized: "Install from Image File"),
                           subtitle: { if case .ipswFile(let u) = source { return u.lastPathComponent } else { return String(localized: "Choose a .ipsw restore image") } }(),
                           badge: nil, selected: { if case .ipswFile = source { return true } else { return false } }()) {
                    chooseIPSW()
                }
                ForEach(CloudImageInstaller.all) { d in
                    SourceTile(icon: "shippingbox", title: d.name, subtitle: String(localized: "Ready-made desktop · set up automatically"),
                               badge: String(localized: "Free"), selected: source == .cloud(d)) {
                        source = .cloud(d)
                        if name == "macOS" { name = d.id.capitalized }
                        memoryGB = 4; diskGB = 32
                    }
                }
                SourceTile(icon: "terminal", title: "Linux",
                           subtitle: { if case .linuxISO(let u) = source { return u.lastPathComponent } else { return String(localized: "Ubuntu, Fedora, Debian… (arm64 .iso)") } }(),
                           badge: nil, selected: isLinux) {
                    chooseLinuxISO()
                }
                SourceTile(icon: "pc", title: "Windows 11",
                           subtitle: { if case .windowsISO(let u, _) = source { return u.lastPathComponent } else { return String(localized: "Arm64 (fast) or x64 (emulated) .iso") } }(),
                           badge: "QEMU", selected: isWindows) {
                    chooseWindowsISO()
                }
            }
            if isWindows {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Architecture", selection: Binding(
                        get: { if case .windowsISO(_, let a) = source { return a } else { return .aarch64 } },
                        set: { a in if case .windowsISO(let u, _) = source { source = .windowsISO(u, a) } })) {
                        Text("Windows 11 on Arm — near-native speed; runs most x64 apps via Prism").tag(VMConfig.Architecture.aarch64)
                        Text("Windows 11 x64 — full emulation, much slower").tag(VMConfig.Architecture.x86_64)
                    }
                    .pickerStyle(.radioGroup)
                    HStack(spacing: 14) {
                        Text("Get the ISO from Microsoft:").foregroundStyle(.secondary)
                        Link("Arm64", destination: WindowsCreator.downloadPageArm)
                        Link("x64", destination: WindowsCreator.downloadPageX64)
                    }
                    if (try? QEMUEnvironment.detect()) == nil {
                        Label("Requires QEMU: brew install qemu swtpm", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
                .font(.callout)
            }
            if isLinux {
                HStack(spacing: 14) {
                    Text("Get an arm64 installer:").foregroundStyle(.secondary)
                    Link("Ubuntu", destination: URL(string: "https://ubuntu.com/download/server/arm")!)
                    Link("Fedora", destination: URL(string: "https://fedoraproject.org/workstation/download")!)
                    Link("Debian", destination: URL(string: "https://www.debian.org/distrib/netinst")!)
                }
                .font(.callout)
            }
            Spacer()
        }
        .padding(28)
    }

    var isLinux: Bool { if case .linuxISO = source { return true } else { return false } }
    var isCloud: Bool { if case .cloud = source { return true } else { return false } }
    var isWindows: Bool { if case .windowsISO = source { return true } else { return false } }

    func chooseWindowsISO() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .diskImage, .diskImage]
        if panel.runModal() == .OK, let url = panel.url {
            let arch: VMConfig.Architecture = url.lastPathComponent.lowercased().contains("x64") ? .x86_64 : .aarch64
            source = .windowsISO(url, arch)
            if name == "macOS" { name = "Windows 11" }
            memoryGB = 8; diskGB = 80
        }
    }

    func chooseLinuxISO() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .diskImage, .diskImage]
        if panel.runModal() == .OK, let url = panel.url {
            source = .linuxISO(url)
            if name == "macOS" { name = url.deletingPathExtension().lastPathComponent.components(separatedBy: "-").first?.capitalized ?? "Linux" }
            memoryGB = 4
            diskGB = 64
        }
    }

    // MARK: Step 2 — name, account, resources

    var details: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(spacing: 10) {
                Image(systemName: isWindows ? "pc" : (isCloud ? "shippingbox" : (isLinux ? "terminal" : "apple.logo"))).font(.system(size: 64, weight: .light))
                Text(sourceLabel).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(width: 170)
            .padding(.top, 30)
            Form {
                Section("Name and Location") {
                    TextField("Name", text: $name)
                    LabeledContent("Saved in", value: VMLibrary.root.path).font(.caption)
                    if nameTaken { Text("A VM with this name already exists.").foregroundStyle(.red).font(.caption) }
                }
                if (provisioningAvailable && !isLinux && !isWindows) || isCloud || isWindows {
                    Section {
                        TextField("Full name", text: $fullName)
                        TextField("Account name", text: $username)
                        SecureField("Password", text: $password)
                    } header: { Text("Your account in the VM") } footer: {
                        Text(isWindows ? "Windows installs unattended with this local account, skips the out-of-box setup and signs in automatically."
                             : "Created on first boot — no Setup Assistant. Logs in automatically and enables SSH so Vitrine can install the Vitrine Agent.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Customize settings before installation", isOn: $customize)
                if customize {
                    Section("Hardware") {
                        ValueSlider("Processors", selection: $cpus, values: Array(2...max(2, ProcessInfo.processInfo.processorCount))) { "\($0)" }
                        ValueSlider("Memory", selection: $memoryGB, values: Array(4...max(4, Int(ProcessInfo.processInfo.physicalMemory >> 30)))) {
                            String(localized: "\($0) GB")
                        }
                        ValueSlider("Disk (grows as needed)", selection: $diskGB,
                                    values: [40, 64, 80, 100, 128, 160, 200, 256, 320, 400, 512, 768, 1024, 1536, 2048]) {
                            $0 >= 1024 && $0 % 1024 == 0 ? String(localized: "\($0 / 1024) TB") : String(localized: "\($0) GB")
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .padding(.horizontal, 20)
    }

    // MARK: Step 3 — progress

    var working: some View {
        VStack(spacing: 18) {
            Image(systemName: "apple.logo").font(.system(size: 72, weight: .light))
            Text(phase).font(.title2.weight(.semibold))
            ProgressView(value: progress).frame(width: 380)
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
    }

    func failed(_ msg: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 48)).foregroundStyle(.orange)
            Text("Installation failed").font(.title2.weight(.semibold))
            Text(msg).textSelection(.enabled).foregroundStyle(.secondary).frame(maxWidth: 520)
        }
    }

    // MARK: Footer

    var footer: some View {
        HStack {
            if step == .details || { if case .failed = step { return true } else { return false } }() {
                Button("Back") { step = step == .details ? .chooseSource : .details }
            }
            Spacer()
            Button("Cancel") { task?.cancel(); dismissWindow(id: "assistant") }
                .keyboardShortcut(.cancelAction)
            switch step {
            case .chooseSource:
                Button("Continue") { step = .details }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            case .details:
                Button("Create") { create() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(!detailsValid)
            default: EmptyView()
            }
        }
        .padding(14)
    }

    var sourceLabel: String {
        switch source {
        case .latestMacOS: return latest.map { "macOS \($0.osVersion)\n(\($0.buildVersion))" } ?? "Latest macOS"
        case .ipswFile(let u), .linuxISO(let u): return u.lastPathComponent
        case .cloud(let d): return d.name
        case .windowsISO(let u, let a): return "\(u.lastPathComponent)\n(\(a == .aarch64 ? "Arm64" : "x64, emulated"))"
        }
    }

    var nameTaken: Bool { FileManager.default.fileExists(atPath: VMLibrary.bundleURL(named: name.trimmingCharacters(in: .whitespaces)).path) }

    var detailsValid: Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !n.contains("/"), !nameTaken else { return false }
        if ((provisioningAvailable && !isLinux && !isWindows) || isCloud || isWindows) && (username.isEmpty || password.count < 4) { return false }
        return true
    }

    func chooseIPSW() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ipsw") ?? .data]
        if panel.runModal() == .OK, let url = panel.url { source = .ipswFile(url) }
    }

    func create() {
        if case .linuxISO(let iso) = source { createLinux(iso: iso); return }
        if case .cloud(let distro) = source { createCloud(distro); return }
        if case .windowsISO(let iso, let arch) = source { createWindows(iso: iso, arch: arch); return }
        var opts = MacInstaller.Options(name: name.trimmingCharacters(in: .whitespaces))
        opts.cpuCount = cpus
        opts.memoryMiB = UInt64(memoryGB) << 10
        opts.diskBytes = UInt64(diskGB) << 30
        if let screen = NSScreen.main {
            let px = CoherenceDisplay.pixels(for: screen)
            opts.display = VMConfig.DisplayConfig(widthPixels: px.width, heightPixels: px.height, pixelsPerInch: px.ppi)
        }
        if provisioningAvailable { opts.account = (fullName, username, password) }
        let src = source
        step = .working
        phase = String(localized: "Preparing…"); detail = ""; progress = 0
        task = Task { @MainActor in
            do {
                let ipsw: URL
                switch src {
                case .ipswFile(let url), .linuxISO(let url): ipsw = url // Linux returns earlier via createLinux
                case .cloud, .windowsISO: return
                case .latestMacOS:
                    let info = try await RestoreImages.latestSupported()
                    phase = String(localized: "Downloading macOS \(info.osVersion)…")
                    ipsw = try await RestoreImages.download(info.url) { f, got, total in
                        Task { @MainActor in
                            progress = f
                            detail = String(localized: "\(formatBytes(UInt64(got))) of \(formatBytes(UInt64(max(total, 0))))")
                        }
                    }
                }
                try Task.checkCancellation()
                phase = String(localized: "Installing macOS…"); detail = String(localized: "This usually takes 10–20 minutes."); progress = 0
                let image = try await RestoreImages.load(ipsw)
                let installer = MacInstaller()
                let bundle = try installer.createBundle(options: opts, restoreImage: image)
                do {
                    try await installer.install(bundle: bundle, ipsw: ipsw) { p in
                        if case .installing(let f) = p { progress = f }
                    }
                } catch {
                    try? FileManager.default.removeItem(at: bundle.url)
                    throw error
                }
                model.refresh()
                dismissWindow(id: "assistant")
                model.start(bundle)
                openWindow(id: "vm", value: bundle.url.path)
            } catch is CancellationError {
            } catch {
                step = .failed(error.localizedDescription)
            }
        }
    }
}

extension InstallationAssistantView {
    func createWindows(iso: URL, arch: VMConfig.Architecture) {
        var o = WindowsCreator.Options(name: name.trimmingCharacters(in: .whitespaces), installISO: iso)
        o.architecture = arch
        // The stepper starts at half the cores, which is the right default for native Arm guests but
        // leaves an emulated x64 guest slow (TCG throughput scales with vCPU count). Use the
        // architecture's default unless the user moved the stepper away from its initial value.
        o.cpuCount = cpus == Self.defaultCPUs ? WindowsCreator.Options.defaultCPUCount(for: arch) : cpus
        o.memoryMiB = UInt64(memoryGB) << 10
        o.diskBytes = UInt64(diskGB) << 30
        o.account = (fullName, username, password)
        o.agentExecutable = AgentInstaller.windowsAgentExecutable(arch: arch)
        step = .working
        phase = String(localized: "Downloading Windows drivers…"); detail = String(localized: "virtio-win (network, input, display)"); progress = 0
        let options = o
        task = Task { @MainActor in
            do {
                let opts = try await WindowsCreator.prepare(options: options) { p in
                    Task { @MainActor in
                        switch p {
                        case .fetchingVirtioWin, .openSSHUnavailable: break // shown before the task; OpenSSH is optional
                        case .virtioWin(let f), .openSSH(let f): progress = f
                        case .fetchingOpenSSH:
                            phase = String(localized: "Downloading OpenSSH…"); detail = String(localized: "for installing the Vitrine Agent and its updates"); progress = 0
                        }
                    }
                }
                phase = String(localized: "Preparing unattended setup…"); detail = ""; progress = 0.95
                let bundle = try WindowsCreator.create(opts)
                model.refresh()
                dismissWindow(id: "assistant")
                model.start(bundle)
                openWindow(id: "vm", value: bundle.url.path)
            } catch is CancellationError {
            } catch {
                step = .failed(error.localizedDescription)
            }
        }
    }

    func createCloud(_ distro: CloudImageInstaller.Distro) {
        var o = CloudImageInstaller.Options(name: name.trimmingCharacters(in: .whitespaces), fullName: fullName,
                                            username: username, password: password)
        o.distro = distro
        o.cpuCount = cpus
        o.memoryMiB = UInt64(memoryGB) << 10
        o.diskBytes = UInt64(diskGB) << 30
        if let screen = NSScreen.main {
            let px = CoherenceDisplay.pixels(for: screen)
            o.display = VMConfig.DisplayConfig(widthPixels: px.width, heightPixels: px.height, pixelsPerInch: px.ppi)
        }
        step = .working
        phase = String(localized: "Downloading \(distro.name)…"); detail = ""; progress = 0
        let options = o
        task = Task { @MainActor in
            do {
                let bundle = try await CloudImageInstaller.create(options) { p in
                    Task { @MainActor in
                        switch p {
                        case .downloading(let f): progress = f
                        case .extracting: phase = String(localized: "Preparing disk…"); progress = 0.5
                        case .configuring: phase = String(localized: "Configuring…"); progress = 0.9
                        }
                    }
                }
                model.refresh()
                dismissWindow(id: "assistant")
                model.start(bundle)
                openWindow(id: "vm", value: bundle.url.path)
            } catch is CancellationError {
            } catch {
                step = .failed(error.localizedDescription)
            }
        }
    }

    func createLinux(iso: URL) {
        var o = LinuxCreator.Options(name: name.trimmingCharacters(in: .whitespaces))
        o.cpuCount = cpus
        o.memoryMiB = UInt64(memoryGB) << 10
        o.diskBytes = UInt64(diskGB) << 30
        o.installISO = iso
        if let screen = NSScreen.main {
            let px = CoherenceDisplay.pixels(for: screen)
            o.display = VMConfig.DisplayConfig(widthPixels: px.width, heightPixels: px.height, pixelsPerInch: px.ppi)
        }
        do {
            let bundle = try LinuxCreator.create(o)
            model.refresh()
            dismissWindow(id: "assistant")
            model.start(bundle)
            openWindow(id: "vm", value: bundle.url.path)
        } catch {
            step = .failed(error.localizedDescription)
        }
    }
}

private struct SourceTile: View {
    let icon: String
    let title: String
    let subtitle: String
    let badge: String?
    let selected: Bool
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon).font(.system(size: 30, weight: .light))
                    Spacer()
                    if let badge {
                        Text(badge).font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(disabled ? Color.secondary.opacity(0.2) : Color.accentColor.opacity(0.18)))
                    }
                }
                Spacer()
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(14)
            .frame(height: 130)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(hovering && !disabled ? 0.07 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .onHover { hovering = $0 }
    }
}
