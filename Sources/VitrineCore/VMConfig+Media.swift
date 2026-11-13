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
        for m in media where m == "seed.iso" { Self.removeGenerated(m, in: bundle) }
        return media
    }

    /// File name of the generated driver disc inside the bundle (see `driverMedia`).
    static let driverDiscFileName = "drivers.iso"

    /// Detaches the driver disc and deletes the generated one. The caller saves the config.
    /// A saved memory state expects the same devices: only call this for a VM that is shut down.
    @discardableResult
    mutating func ejectDriverMedia(in bundle: VMBundle) -> String? {
        guard let media = driverMedia else { return nil }
        driverMedia = nil
        if media == Self.driverDiscFileName { Self.removeGenerated(media, in: bundle) }
        return media
    }

    /// Deletes a disc Vitrine generated directly inside the bundle. A relative spelling alone does
    /// not establish ownership: a symlink may lead outside the bundle, and such a file is left alone.
    private static func removeGenerated(_ name: String, in bundle: VMBundle) {
        let root = bundle.url.resolvingSymlinksInPath().standardizedFileURL
        let candidate = bundle.resolve(name)
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.deletingLastPathComponent() == root,
              resolved.lastPathComponent == name,
              (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return }
        try? FileManager.default.removeItem(at: candidate)
    }
}
