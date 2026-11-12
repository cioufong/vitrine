import SwiftUI
import AppKit
import VitrineCore
import VitrineVZ
import VitrineQEMU

/// Importing a VM from another tool (File ▸ Import…, or a drop on the Control Center), one at a
/// time: the source is inspected off the main thread, the user reviews the plan in a sheet, and the
/// import runs off the main thread with a Cancel that stops qemu-img. The engine creates the bundle
/// locked and hidden (VMBundle.create), so a cancelled or failed import leaves nothing behind, and
/// one interrupted by a crash is moved to the Trash at the next launch.
@MainActor
final class VMImportSession: ObservableObject {
    /// What is being imported, as the review sheet shows it.
    struct Review {
        var source: URL
        var kind: ImportSource
        /// Whole-VM imports: the engine's plan.
        var plan: ImportPlan?
        /// Disk image imports: what qemu-img says about the image (nil when it couldn't be read).
        var diskInfo: DiskImport.Info?
        /// Things in the way found by the app itself (disk images: qemu-img missing or the image unreadable).
        var blockers: [ImportPlan.Issue] = []
    }

    enum Step {
        case inspecting(URL)
        case review(Review)
        case importing(Review)
        /// Imported, with notes the user should read (UTM imports report theirs only afterwards).
        case finished(name: String, notes: [String])
        case failed(message: String, review: Review?)
    }

    /// nil: no import (the sheet is closed).
    @Published private(set) var step: Step?
    /// The engine's latest step while importing ("converting disk 1 of 2 (…)").
    @Published private(set) var status = ""
    @Published private(set) var cancelling = false

    // What the user can change in the review sheet.
    @Published var name = ""
    @Published var cpuCount = 2
    @Published var memoryMiB: UInt64 = 4096
    @Published var guestOS: VMConfig.GuestOS = .linux
    @Published var architecture: VMConfig.Architecture = .aarch64

    /// Called on the main actor with the new VM once an import has finished.
    var onImported: ((VMBundle) -> Void)?

    private var cancellation: DiskImport.Cancellation?
    private var work: Task<Void, Never>?
    /// The name filled in when the review started (UTM: kept from the bundle unless changed).
    private var initialName = ""

    var isActive: Bool { step != nil }

    /// Inspecting or importing: something runs that quitting must stop.
    var isBusy: Bool {
        switch step {
        case .inspecting, .importing: return true
        default: return false
        }
    }

    // MARK: Starting

    /// Starts importing `url`; false (with `problem` set) when it isn't something Vitrine imports.
    @discardableResult
    func begin(_ url: URL, problem: inout String?) -> Bool {
        guard !isActive else { return false }
        let kind: ImportSource
        do {
            guard let k = try ImportSource.classify(url) else {
                problem = String(localized: "Choose an OVA or OVF package, a VMware, Parallels Desktop, VirtualBox or UTM virtual machine, or a disk image (qcow2, VMDK, VHD, VHDX, VDI or raw).")
                return false
            }
            kind = k
        } catch {
            problem = error.localizedDescription
            return false
        }
        cancelling = false
        status = ""
        switch kind {
        case .wholeVM:
            inspectWholeVM(url)
        case .diskImage:
            inspectDisk(url)
        case .utm:
            let name = ImportSource.suggestedName(for: url)
            startReview(Review(source: url, kind: .utm), name: name)
        }
        return true
    }

    private func inspectWholeVM(_ url: URL) {
        let token = DiskImport.Cancellation()
        cancellation = token
        step = .inspecting(url)
        work = Task {
            do {
                let plan = try await Self.offMain { try WholeVMImporter.inspect(url, cancellation: token) }
                let review = Review(source: url, kind: .wholeVM(plan.format), plan: plan)
                cpuCount = plan.cpuCount
                memoryMiB = plan.memoryMiB
                startReview(review, name: plan.name)
            } catch let e as VitrineError where e == .cancelled {
                step = nil
            } catch {
                step = token.isCancelled ? nil : .failed(message: error.localizedDescription, review: nil)
            }
        }
    }

    private func inspectDisk(_ url: URL) {
        let token = DiskImport.Cancellation()
        cancellation = token
        step = .inspecting(url)
        work = Task {
            var review = Review(source: url, kind: .diskImage)
            if DiskImport.isQemuImgAvailable {
                do {
                    review.diskInfo = try await Self.offMain { try DiskImport.info(url, cancellation: token) }
                } catch {
                    review.blockers.append(.init(.diskFormat, "\(url.lastPathComponent) can't be read as a disk image: \(error.localizedDescription)"))
                }
            } else {
                review.blockers.append(.init(.qemuMissing, "reading disk images needs qemu-img; install QEMU (brew install qemu) and try again"))
            }
            guard !token.isCancelled else { step = nil; return }
            cpuCount = max(2, ProcessInfo.processInfo.processorCount / 2)
            memoryMiB = min(4096, Self.hostMemoryMiB)
            (guestOS, architecture) = Self.guessGuest(fromFileName: url.lastPathComponent)
            startReview(review, name: ImportSource.suggestedName(for: url))
        }
    }

    private func startReview(_ review: Review, name: String) {
        self.name = name
        initialName = name
        step = .review(review)
    }

    /// A guess from the file name ("…-amd64.qcow2", "Win11_arm64.vhdx"); the user can change it.
    nonisolated static func guessGuest(fromFileName file: String) -> (VMConfig.GuestOS, VMConfig.Architecture) {
        let lower = file.lowercased()
        let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let x86 = words.contains { ["amd64", "x64", "i686", "win64"].contains($0) } || lower.contains("x86_64") || lower.contains("x86-64")
        let windows = lower.contains("windows") || words.contains { $0 == "win" || ($0.hasPrefix("win1") && $0.count <= 5) }
        return (windows ? .windows : .linux, x86 ? .x86_64 : .aarch64)
    }

    // MARK: Review

    enum NameProblem: Equatable { case empty, invalid, taken }

    /// Why `name` can't be the new VM's name: the engine's rule (`VMCreationJob.isValidVMName`), and
    /// no VM of that name in the library.
    nonisolated static func nameProblem(_ name: String,
                                        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: VMLibrary.bundleURL(named: $0).path) }) -> NameProblem? {
        if name.isEmpty { return .empty }
        guard VMCreationJob.isValidVMName(name) else { return .invalid }
        return exists(name) ? .taken : nil
    }

    var nameProblem: NameProblem? { Self.nameProblem(name) }

    /// The plan's warnings that still apply to what the sheet shows: the name ones are worked out
    /// live from the name field instead.
    nonisolated static func visibleWarnings(_ plan: ImportPlan, name: String) -> [ImportPlan.Issue] {
        plan.warnings.filter {
            switch $0.code {
            case .nameTaken, .invalidName: return false
            case .nameChanged: return name == plan.name
            default: return true
            }
        }
    }

    /// The review's warnings and blockers as the sheet shows them (localized, see ImportIssueText).
    func warnings(for review: Review) -> [ImportIssueText.Line] {
        if let plan = review.plan {
            return Self.visibleWarnings(plan, name: name).map { ImportIssueText.line(for: $0, plan: plan) }
        }
        guard review.kind == .diskImage else { return [] }
        var out: [ImportIssueText.Line] = []
        if architecture == .x86_64 {
            out.append(ImportIssueText.line(for: .init(.emulated, "x86_64 guests are emulated on Apple silicon (QEMU) and run many times slower than native ones"), plan: nil))
        }
        if backend == .qemu, (try? QEMUEnvironment.detect()) == nil {
            out.append(.init(text: String(localized: "This virtual machine runs on QEMU, which isn't installed. Install it (brew install qemu) before starting the VM.")))
        }
        return out
    }

    func blockers(for review: Review) -> [ImportIssueText.Line] {
        ((review.plan?.blockers ?? []) + review.blockers).map { ImportIssueText.line(for: $0, plan: review.plan) }
    }

    /// Where a disk image import runs (as `VMImporter.importDisk` decides it).
    var backend: VMConfig.Backend { guestOS == .linux && architecture == .aarch64 ? .vz : .qemu }

    func canImport(_ review: Review) -> Bool { blockers(for: review).isEmpty && nameProblem == nil }

    // MARK: Importing

    func startImport() {
        guard case .review(let review) = step, canImport(review) else { return }
        let token = DiskImport.Cancellation()
        cancellation = token
        cancelling = false
        status = ""
        step = .importing(review)
        let name = name, cpus = cpuCount, memory = memoryMiB, os = guestOS, arch = architecture
        let utmName: String? = name == initialName ? nil : name
        work = Task {
            do {
                let result: (VMBundle, [String])
                switch review.kind {
                case .wholeVM:
                    guard let plan = review.plan else { return }
                    var overrides = WholeVMImporter.Overrides(name: name)
                    if cpus != plan.cpuCount { overrides.cpuCount = cpus }
                    if memory != plan.memoryMiB { overrides.memoryMiB = memory }
                    let bundle = try await Self.offMain {
                        try WholeVMImporter.execute(plan, overrides: overrides, cancellation: token) { line in
                            DispatchQueue.main.async { MainActor.assumeIsolated { self.status = line } }
                        }
                    }
                    result = (bundle, [])
                case .diskImage:
                    var o = VMImporter.DiskOptions(name: name)
                    o.guestOS = os; o.architecture = arch; o.cpuCount = cpus; o.memoryMiB = memory
                    let source = review.source
                    let bundle = try await Self.offMain { try VMImporter.importDisk(source, o, cancellation: token) }
                    result = (bundle, [])
                case .utm:
                    let source = review.source
                    let r = try await Self.offMain { try UTMImporter.importVM(source, name: utmName, cancellation: token) }
                    result = (r.bundle, r.notes)
                }
                onImported?(result.0)
                step = result.1.isEmpty ? nil : .finished(name: result.0.name, notes: result.1)
            } catch let e as VitrineError where e == .cancelled {
                step = nil
            } catch {
                step = token.isCancelled ? nil : .failed(message: error.localizedDescription, review: review)
            }
        }
    }

    /// The step line for the progress view: the engine's (English) step, localized where it is one
    /// the app knows.
    var localizedStatus: String {
        Self.localizedStatus(status, kind: { if case .importing(let r) = step { return r.kind } else { return nil } }())
    }

    nonisolated static func localizedStatus(_ line: String, kind: ImportSource?) -> String {
        if let m = line.firstMatch(of: #/^converting disk (\d+) of (\d+)/#), let i = Int(m.1), let n = Int(m.2) {
            return String(localized: "Converting disk \(i) of \(n)…")
        }
        if !line.isEmpty { return line }
        switch kind {
        case .diskImage: return String(localized: "Converting the disk…")
        case .utm: return String(localized: "Copying the virtual machine…")
        default: return String(localized: "Preparing…")
        }
    }

    // MARK: Ending

    /// Cancel in the sheet: stops what runs (the engine removes a half-made VM), or closes the sheet.
    func cancel() {
        if isBusy {
            cancelling = true
            cancellation?.cancel()
        } else {
            step = nil
        }
    }

    /// Back from a failed import to its review.
    func back() {
        if case .failed(_, let review?) = step { step = .review(review) } else { step = nil }
    }

    func close() { if !isBusy { step = nil } }

    /// For quitting: stops what runs and waits until the engine has cleaned up.
    func cancelAndWait() async {
        guard isBusy else { return }
        cancel()
        await work?.value
    }

    // MARK: Helpers

    nonisolated static var hostMemoryMiB: UInt64 { ProcessInfo.processInfo.physicalMemory / (1 << 20) }

    /// Runs blocking engine work (qemu-img, hashing, copying) on a background queue.
    nonisolated static func offMain<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try body() })
            }
        }
    }
}

extension VMImportSession.Step {
    var isReview: Bool { if case .review = self { return true } else { return false } }
}

extension AppModel {
    /// File ▸ Import…: asks for a VM or disk image and starts importing it.
    func chooseImportSource() {
        guard !importSession.isActive else { return } // its sheet is already up
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import a Virtual Machine")
        panel.message = String(localized: "Choose an OVA or OVF package, a VMware, Parallels Desktop, VirtualBox or UTM virtual machine, or a disk image.")
        panel.prompt = String(localized: "Import")
        panel.canChooseFiles = true
        // .pvm and .vmwarevm bundles are plain folders when Parallels or VMware isn't installed.
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        let filter = ImportPanelFilter()
        panel.delegate = filter
        let response = withExtendedLifetime(filter) { panel.runModal() }
        guard response == .OK, let url = panel.url else { return }
        beginImport(url)
    }

    /// Starts importing `url` (from the open panel or a drop), or says why it can't.
    func beginImport(_ url: URL) {
        var problem: String?
        if !importSession.begin(url, problem: &problem), let problem {
            alert = AlertItem(title: String(localized: "Vitrine can't import “\(url.lastPathComponent)”"), message: problem)
        }
    }
}

/// Greys out files the open panel can't import (folders stay enabled: a VM folder is chosen as a whole).
private final class ImportPanelFilter: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool { ImportSource.isSelectable(url) }
}
