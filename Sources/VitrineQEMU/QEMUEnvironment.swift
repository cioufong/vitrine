import Foundation
import VitrineCore

/// Locates the QEMU installation (Homebrew or bundled with the app) and its firmware.
/// QEMU is GPL-licensed and always runs as a separate process; Vitrine never links it.
public struct QEMUEnvironment: Sendable, Equatable {
    public var binDirectory: URL
    public var shareDirectory: URL

    public init(binDirectory: URL, shareDirectory: URL) {
        self.binDirectory = binDirectory
        self.shareDirectory = shareDirectory
    }

    public static func detect() throws -> QEMUEnvironment {
        var prefixes: [URL] = []
        if let env = ProcessInfo.processInfo.environment["VITRINE_QEMU_PREFIX"] { prefixes.append(URL(fileURLWithPath: env)) }
        if let res = Bundle.main.resourceURL { prefixes.append(res.appendingPathComponent("qemu")) }
        prefixes += ["/opt/homebrew", "/usr/local"].map { URL(fileURLWithPath: $0) }
        for p in prefixes {
            let bin = p.appendingPathComponent("bin"), share = p.appendingPathComponent("share/qemu")
            if FileManager.default.isExecutableFile(atPath: bin.appendingPathComponent("qemu-system-aarch64").path),
               FileManager.default.fileExists(atPath: share.appendingPathComponent("edk2-aarch64-code.fd").path) {
                return QEMUEnvironment(binDirectory: bin, shareDirectory: share)
            }
        }
        throw VitrineError.unsupported("QEMU not found — install it with `brew install qemu` (and `brew install swtpm` for Windows 11)")
    }

    public func system(_ arch: VMConfig.Architecture) -> URL {
        binDirectory.appendingPathComponent(arch == .aarch64 ? "qemu-system-aarch64" : "qemu-system-x86_64")
    }

    public func firmwareCode(_ arch: VMConfig.Architecture) -> URL {
        shareDirectory.appendingPathComponent(arch == .aarch64 ? "edk2-aarch64-code.fd" : "edk2-x86_64-secure-code.fd")
    }

    /// Template for the per-VM writable UEFI variable store.
    public func firmwareVarsTemplate(_ arch: VMConfig.Architecture) -> URL {
        shareDirectory.appendingPathComponent(arch == .aarch64 ? "edk2-arm-vars.fd" : "edk2-i386-vars.fd")
    }

    /// Whether a UEFI variable store of `size` bytes fits the firmware Vitrine starts `arch` guests
    /// with. QEMU refuses to start with one of another size: the aarch64 `virt` machine's flash
    /// banks are 64 MiB, and the x86_64 store must be as large as QEMU's own template. Other tools
    /// ship firmware builds with other layouts (UTM's aarch64 store is 640 KiB).
    public static func variableStoreFits(size: UInt64, _ arch: VMConfig.Architecture) -> Bool {
        if arch == .aarch64 { return size == 64 << 20 }
        guard let template = try? detect().firmwareVarsTemplate(arch),
              let expected = (try? FileManager.default.attributesOfItem(atPath: template.path))?[.size] as? UInt64 else { return true }
        return size == expected
    }

    /// swtpm (TPM 2.0 emulator) for Windows 11, if installed.
    public var swtpm: URL? {
        let candidates = [binDirectory.appendingPathComponent("swtpm"), URL(fileURLWithPath: "/opt/homebrew/bin/swtpm")]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
