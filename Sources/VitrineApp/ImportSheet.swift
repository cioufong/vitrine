import SwiftUI
import UniformTypeIdentifiers
import VitrineCore
import VitrineVZ

/// Shows the import sheet on the Control Center while an import is under way, and takes VMs and
/// disk images dropped on it.
struct ImportHost: ViewModifier {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: VMImportSession
    @State private var dropTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08)))
                        .overlay {
                            Label("Drop to import", systemImage: "square.and.arrow.down")
                                .font(.title3.weight(.semibold))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(.regularMaterial, in: Capsule())
                        }
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard !session.isActive, let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { model.beginImport(url) } }
                }
                return true
            }
            .sheet(isPresented: Binding(get: { session.isActive }, set: { if !$0 { session.close() } })) {
                ImportSheet(session: session)
                    .interactiveDismissDisabled(session.isBusy)
            }
    }
}

struct ImportSheet: View {
    @ObservedObject var session: VMImportSession

    var body: some View {
        VStack(spacing: 0) {
            switch session.step {
            case .inspecting(let url):
                busy(title: String(localized: "Reading “\(url.lastPathComponent)”…"), detail: nil)
            case .review(let review):
                ImportReviewForm(session: session, review: review)
            case .importing:
                busy(title: String(localized: "Importing “\(session.name)”…"),
                     detail: session.cancelling ? String(localized: "Cancelling…") : session.localizedStatus)
            case .finished(let name, let notes):
                finished(name: name, notes: notes)
            case .failed(let message, _):
                failed(message)
            case nil:
                EmptyView()
            }
            Divider()
            footer
        }
        .frame(width: 600)
    }

    private func busy(title: String, detail: String?) -> some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            if let detail { Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
        .padding(30)
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private func finished(name: String, notes: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Imported “\(name)”", systemImage: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
                .symbolRenderingMode(.multicolor)
            Text("Check these before starting it:").foregroundStyle(.secondary)
            ForEach(notes, id: \.self) { note in
                IssueRow(line: .init(text: ImportIssueText.sentence(note)), severity: .warning)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(.orange)
            Text("Import failed").font(.title2.weight(.semibold))
            Text(message).textSelection(.enabled).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .padding(30)
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    @ViewBuilder private var footer: some View {
        HStack {
            if case .failed(_, let review) = session.step, review != nil {
                Button("Back") { session.back() }
            }
            Spacer()
            switch session.step {
            case .review(let review):
                Button("Cancel") { session.cancel() }.keyboardShortcut(.cancelAction)
                Button("Import") { session.startImport() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(!session.canImport(review))
            case .inspecting, .importing:
                Button("Cancel") { session.cancel() }.keyboardShortcut(.cancelAction).disabled(session.cancelling)
            default:
                Button("Done") { session.close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }
}

private struct ImportReviewForm: View {
    @ObservedObject var session: VMImportSession
    let review: VMImportSession.Review

    private var plan: ImportPlan? { review.plan }
    private let hostCPUs = ProcessInfo.processInfo.processorCount
    private let hostGB = Int(VMImportSession.hostMemoryMiB >> 10)

    var body: some View {
        let blockers = session.blockers(for: review)
        let warnings = session.warnings(for: review)
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 34, weight: .light)).frame(width: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import “\(review.source.lastPathComponent)”").font(.title3.weight(.semibold)).lineLimit(1)
                    Text(sourceLabel).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 6)
            Form {
                Section("Name and Location") {
                    TextField("Name", text: $session.name)
                    LabeledContent("Saved in", value: VMLibrary.root.path).font(.caption)
                    if let problem = session.nameProblem {
                        Text(nameProblemText(problem)).foregroundStyle(.red).font(.caption)
                    }
                }
                if !blockers.isEmpty || !warnings.isEmpty {
                    Section {
                        ForEach(blockers, id: \.self) { IssueRow(line: $0, severity: .blocker) }
                        ForEach(warnings, id: \.self) { IssueRow(line: $0, severity: .warning) }
                    } header: {
                        Text(blockers.isEmpty ? "Before you import" : "This virtual machine can't be imported")
                    }
                }
                system
                if review.kind != .utm {
                    Section("Hardware") {
                        ValueSlider("Processors", selection: $session.cpuCount, values: Array(2...max(2, hostCPUs))) { "\($0)" }
                        ValueSlider("Memory", selection: $session.memoryMiB,
                                    values: (4...max(4, hostGB)).map { UInt64($0) << 10 }) { ImportIssueText.memoryLabel($0) }
                    }
                }
                disks
                if let plan {
                    Section("Network") {
                        LabeledContent("Network", value: plan.networkDisabled ? String(localized: "None") : String(localized: "Shared Network (NAT)"))
                        if !plan.networkDisabled {
                            LabeledContent("MAC address") {
                                Text(plan.macAddress ?? String(localized: "New, random")).monospaced(plan.macAddress != nil)
                            }
                        }
                    }
                }
                if review.kind == .utm {
                    Section {
                        Text("Settings come from the UTM virtual machine. Anything that can't be carried over is listed once the import is done.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(height: 580)
    }

    private var icon: String {
        switch review.kind {
        case .diskImage: return "internaldrive"
        case .utm: return "shippingbox"
        case .wholeVM: return "square.and.arrow.down.on.square"
        }
    }

    private var sourceLabel: String {
        switch review.kind {
        case .wholeVM(let f): return f.displayName
        case .utm: return "UTM"
        case .diskImage: return String(localized: "Disk image")
        }
    }

    private func nameProblemText(_ p: VMImportSession.NameProblem) -> String {
        switch p {
        case .empty: return String(localized: "Enter a name for the virtual machine.")
        case .invalid: return String(localized: "Names use letters, digits, “.”, “-” and “_” (up to 64, starting with a letter or digit).")
        case .taken: return String(localized: "A VM with this name already exists.")
        }
    }

    private func osLabel(_ os: VMConfig.GuestOS) -> String {
        switch os {
        case .linux: return "Linux"
        case .windows: return "Windows"
        case .macOS: return "macOS"
        }
    }

    private func engineLabel(_ backend: VMConfig.Backend, _ arch: VMConfig.Architecture) -> String {
        backend == .vz ? "Virtualization.framework"
            : (arch == .x86_64 ? String(localized: "QEMU (emulated)") : "QEMU")
    }

    @ViewBuilder private var system: some View {
        if let plan {
            Section("System") {
                LabeledContent("Operating system", value: osLabel(plan.guestOS))
                LabeledContent("Architecture", value: ImportIssueText.architectureLabel(plan.architecture))
                LabeledContent("Runs on", value: engineLabel(plan.backend, plan.architecture))
                LabeledContent("Firmware") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(firmwareLabel(plan.firmware))
                        if let b = plan.bootDisk {
                            Text(b.summary).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
        } else if review.kind == .diskImage {
            Section {
                Picker("Operating system", selection: $session.guestOS) {
                    Text(verbatim: "Linux").tag(VMConfig.GuestOS.linux)
                    Text(verbatim: "Windows").tag(VMConfig.GuestOS.windows)
                }
                Picker("Architecture", selection: $session.architecture) {
                    Text(verbatim: "Arm64").tag(VMConfig.Architecture.aarch64)
                    Text("x86_64 (emulated)").tag(VMConfig.Architecture.x86_64)
                }
                LabeledContent("Runs on", value: engineLabel(session.backend, session.architecture))
                LabeledContent("Firmware", value: "UEFI")
            } header: { Text("System") } footer: {
                Text("A disk image doesn't say what it holds: choose the system installed on it. The VM starts with UEFI, so the disk needs an EFI boot loader.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func firmwareLabel(_ f: ImportPlan.Firmware) -> String {
        switch f {
        case .uefi: return "UEFI"
        case .bios: return String(localized: "BIOS only")
        case .unknown: return String(localized: "Unknown")
        }
    }

    @ViewBuilder private var disks: some View {
        if let plan, !plan.disks.isEmpty {
            Section("Disks") {
                ForEach(Array(plan.disks.enumerated()), id: \.offset) { i, d in
                    LabeledContent {
                        Text(diskDescription(format: d.format, size: d.virtualSize, readOnly: d.readOnly))
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(i == 0 ? String(localized: "System disk") : String(localized: "Disk \(i + 1)"))
                            Text(verbatim: "\(d.member?.name ?? d.file.lastPathComponent) (\(d.label))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
            }
        } else if review.kind == .diskImage, let info = review.diskInfo {
            Section("Disks") {
                LabeledContent {
                    Text(diskDescription(format: info.format, size: info.virtualSize, readOnly: false))
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("System disk")
                        Text(verbatim: review.source.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
    }

    private func diskDescription(format: String, size: UInt64?, readOnly: Bool) -> String {
        let names = ["vpc": "VHD", "parallels": "Parallels", "raw": "Raw"]
        var parts = [names[format] ?? format.uppercased()]
        if let size { parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .binary)) }
        if readOnly { parts.append(String(localized: "Read-only")) }
        return parts.joined(separator: " · ")
    }
}

/// A warning (yellow) or a reason the import can't go ahead (red).
private struct IssueRow: View {
    enum Severity { case warning, blocker }
    let line: ImportIssueText.Line
    let severity: Severity

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: severity == .blocker ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(severity == .blocker ? Color.red : Color.yellow)
            VStack(alignment: .leading, spacing: 3) {
                Text(line.text).fixedSize(horizontal: false, vertical: true)
                if let detail = line.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
