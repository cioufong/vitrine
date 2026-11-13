import Foundation
import VitrineCore

/// The import engine's warnings and blockers for the review sheet. The engine words them in English
/// and gives each a stable code; other languages get a sentence per code, with the engine's message
/// underneath where it names the disk, file or setting concerned. English shows the engine's message.
enum ImportIssueText {
    struct Line: Hashable {
        var text: String
        /// The engine's message, when `text` doesn't carry its specifics.
        var detail: String? = nil
    }

    /// Whether the app runs in English (then the engine's own messages read best).
    static var appIsEnglish: Bool { Bundle.main.preferredLocalizations.first?.hasPrefix("en") ?? true }

    static func line(for issue: ImportPlan.Issue, plan: ImportPlan?, english: Bool = appIsEnglish, bundle: Bundle = .main) -> Line {
        guard !english, let text = localized(issue.code, plan: plan, bundle: bundle) else {
            return Line(text: sentence(issue.message))
        }
        return Line(text: text, detail: showsDetail(issue.code) ? sentence(issue.message) : nil)
    }

    /// Codes whose localized sentence leaves out what the engine's message names (which disk, which file).
    static func showsDetail(_ code: ImportPlan.Issue.Code) -> Bool {
        switch code {
        case .pathOutsideSource, .diskMissing, .diskFormat, .archive, .manifest, .unreadableConfig, .physicalDisk,
             .mediaSkipped, .noFallbackLoader, .snapshots, .encrypted, .other:
            return true
        default:
            return false
        }
    }

    /// The engine's message as a sentence: capitalized, ending in a full stop.
    static func sentence(_ message: String) -> String {
        guard let first = message.first else { return message }
        // "x86_64 guests…", "qemu-img …" keep their case: only a plain lowercase word is capitalized.
        let word = message.prefix { !$0.isWhitespace }
        var s = word.allSatisfy({ $0.isLetter && $0.isLowercase }) ? first.uppercased() + message.dropFirst() : message
        if let last = s.last, !".!?".contains(last) { s += "." }
        return s
    }

    static func memoryLabel(_ mib: UInt64, bundle: Bundle = .main) -> String {
        mib % 1024 == 0 ? String(localized: "\(Int(mib / 1024)) GB", bundle: bundle)
                        : String(localized: "\(Int(mib)) MB", bundle: bundle)
    }

    static func architectureLabel(_ a: VMConfig.Architecture) -> String { a == .aarch64 ? "Arm64" : "x86_64" }

    /// A sentence for `code` in the app's language; nil for codes only the engine's message describes.
    static func localized(_ code: ImportPlan.Issue.Code, plan: ImportPlan?, bundle: Bundle = .main) -> String? {
        let app = plan?.format.displayName ?? "VM"
        let cpus = plan?.cpuCount ?? 0
        let memory = memoryLabel(plan?.memoryMiB ?? 0, bundle: bundle)
        switch code {
        // Blockers
        case .pathOutsideSource:
            return String(localized: "A disk is outside the VM's folder. Only disks inside it can be imported.", bundle: bundle)
        case .diskMissing:
            return String(localized: "A disk of the VM is missing.", bundle: bundle)
        case .diskFormat:
            return String(localized: "A disk is in a form Vitrine can't import.", bundle: bundle)
        case .noDisks:
            return String(localized: "The VM has no disk to import.", bundle: bundle)
        case .snapshots:
            return String(localized: "The VM has snapshots. Delete them in \(app) first so its disks are merged, then import it.", bundle: bundle)
        case .savedState:
            return String(localized: "The VM is suspended in \(app). Resume it and shut it down before importing.", bundle: bundle)
        case .encrypted:
            return String(localized: "The VM is encrypted in \(app). Remove the encryption there first.", bundle: bundle)
        case .running:
            return String(localized: "The VM seems to be open in \(app). Shut it down and quit \(app) before importing.", bundle: bundle)
        case .biosOnly:
            return String(localized: "The VM boots only with legacy BIOS, and Vitrine starts VMs with UEFI. Convert the guest to UEFI in \(app) first (or reinstall it).", bundle: bundle)
        case .noBootPartition:
            return String(localized: "Vitrine can't read the boot disk's partition table, so it can't tell whether the VM boots with UEFI.", bundle: bundle)
        case .macOSGuest:
            return String(localized: "macOS VMs can't be imported: a macOS guest is tied to its platform identity, which doesn't carry over. Create a new macOS VM instead.", bundle: bundle)
        case .unsupportedArchitecture:
            return String(localized: "The guest is 32-bit. Only arm64 and x86_64 guests are supported.", bundle: bundle)
        case .archive:
            return String(localized: "The package can't be read.", bundle: bundle)
        case .manifest:
            return String(localized: "The package doesn't match its manifest: it is damaged or was altered.", bundle: bundle)
        case .multipleVMs:
            return String(localized: "The package holds more than one virtual machine. Only single-VM packages can be imported.", bundle: bundle)
        case .unreadableConfig:
            return String(localized: "The VM's configuration can't be read.", bundle: bundle)
        case .physicalDisk:
            return String(localized: "The VM uses a physical disk. Only disk image files can be imported.", bundle: bundle)
        case .qemuMissing:
            return String(localized: "Reading the disks needs qemu-img. Install QEMU (brew install qemu) and try again.", bundle: bundle)
        case .invalidName:
            return String(localized: "Names use letters, digits, “.”, “-” and “_” (up to 64, starting with a letter or digit).", bundle: bundle)
        // Warnings
        case .nameChanged:
            return String(localized: "Named the VM “\(plan?.name ?? "")”: VM names use letters, digits, “.”, “-” and “_”.", bundle: bundle)
        case .nameTaken:
            return String(localized: "A VM with this name already exists.", bundle: bundle)
        case .cpusReduced:
            return String(localized: "Reduced the processors to \(cpus), the number this Mac has.", bundle: bundle)
        case .cpusMissing:
            return String(localized: "\(app) doesn't say how many processors the VM has; gave it \(cpus).", bundle: bundle)
        case .memoryRaised:
            return String(localized: "Raised the memory to \(memory), Vitrine's minimum.", bundle: bundle)
        case .memoryReduced:
            return String(localized: "Reduced the memory to \(memory), the amount this Mac has.", bundle: bundle)
        case .memoryMissing:
            return String(localized: "\(app) doesn't say how much memory the VM has; gave it \(memory).", bundle: bundle)
        case .macReplaced:
            return String(localized: "The VM's MAC address isn't usable; it gets a new one.", bundle: bundle)
        case .emulated:
            return String(localized: "x86_64 guests are emulated on Apple silicon (QEMU) and run many times slower than native ones.", bundle: bundle)
        case .firmwareConfig:
            return String(localized: "\(app) boots this VM with BIOS, but its disk also has a UEFI boot loader; Vitrine boots it with UEFI.", bundle: bundle)
        case .noFallbackLoader:
            return String(localized: "The VM may not find its boot loader: the disk has no fallback loader, and the boot entries kept by \(app) aren't imported.", bundle: bundle)
        case .nvramNotImported:
            return String(localized: "The VM's UEFI variables aren't imported; the guest boots through its disk's fallback loader.", bundle: bundle)
        case .tpmNotImported:
            return String(localized: "The VM's virtual TPM isn't imported.", bundle: bundle)
        case .mediaSkipped:
            return String(localized: "A CD/DVD image was left out; attach it again if you still need it.", bundle: bundle)
        case .guestOSAssumed:
            return String(localized: "\(app) doesn't say which OS the VM runs; assumed Linux. Change it in the VM's configuration if that's wrong.", bundle: bundle)
        case .architectureFromDisk:
            let arch = architectureLabel(plan?.architecture ?? .aarch64)
            // Two cases share the code: the source said otherwise, or said nothing and the disk didn't tell.
            if plan?.warnings.contains(where: { $0.code == code && $0.message.hasPrefix("couldn't tell") }) == true {
                return String(localized: "Couldn't tell the VM's architecture; assumed \(arch).", bundle: bundle)
            }
            return String(localized: "Imported as \(arch), the architecture of the boot loader on its disk.", bundle: bundle)
        case .signatureNotChecked:
            return String(localized: "The package is signed. Vitrine checks its manifest but not the signature.", bundle: bundle)
        case .networkDrivers:
            return String(localized: "The guest gets virtio/NVMe disks and a virtio network adapter, so its network interface may get a new name.", bundle: bundle)
        case .cleanShutdown:
            return String(localized: "\(app) recorded no clean shutdown for this VM; its file systems may need checking on first boot.", bundle: bundle)
        case .basicDisplay:
            return String(localized: "Windows starts on a basic display at a fixed resolution and, on Arm, without network. Attach the driver disc under Configuration ▸ Hard Disk and run install.cmd from it in Windows, then turn off Basic display under Configuration ▸ Graphics.", bundle: bundle)
        case .other:
            return nil
        }
    }
}
