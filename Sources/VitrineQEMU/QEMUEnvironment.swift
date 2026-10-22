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

    /// swtpm (TPM 2.0 emulator) for Windows 11, if installed.
    public var swtpm: URL? {
        let candidates = [binDirectory.appendingPathComponent("swtpm"), URL(fileURLWithPath: "/opt/homebrew/bin/swtpm")]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
