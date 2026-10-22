import Foundation

public extension VMConfig {
    /// Installer or seed media still attached (Windows setup, cloud-init seeds).
    var hasInstallMedia: Bool { installMedia != nil || !(extraMedia ?? []).isEmpty }

    /// Detaches installer and seed media after installation. The generated seed disc inside the
    /// bundle carries the account password, so it is deleted. User installer images are preserved.
    /// The caller saves the config.
    /// A saved memory state expects the same devices: only call this for a VM that is shut down.
    @discardableResult
    mutating func ejectInstallMedia(in bundle: VMBundle) -> [String] {
        let media = (extraMedia ?? []) + [installMedia].compactMap { $0 }
        installMedia = nil
        extraMedia = nil
        windowsSetupAgentSeen = nil
        windowsSetupOffline = nil
        let root = bundle.url.resolvingSymlinksInPath().standardizedFileURL
        for m in media where m == "seed.iso" {
            let candidate = bundle.resolve(m)
            // A relative spelling alone does not establish ownership: a symlink may lead outside
            // the bundle. Only Vitrine's generated, direct seed file is eligible for cleanup.
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.deletingLastPathComponent() == root,
                  resolved.lastPathComponent == "seed.iso",
                  (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
            try? FileManager.default.removeItem(at: candidate)
        }
        return media
    }
}
