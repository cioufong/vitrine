import AppKit
import VitrineAgentProtocol

/// Receives files the host dropped into the "Vitrine Transfer" share and moves them to the Desktop.
enum FileDropHandler {
    static let transferRoot = URL(fileURLWithPath: "/Volumes/My Shared Files", isDirectory: true)
        .appendingPathComponent(transferShareName, isDirectory: true)

    static var isAvailable: Bool { FileManager.default.fileExists(atPath: transferRoot.path) }

    /// Moves each file to ~/Desktop (renaming on conflict) and reveals them in Finder.
    static func handle(_ drop: FileDrop, log: (String) -> Void) {
        let fm = FileManager.default
        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        var placed: [URL] = []
        var batches = Set<String>()
        for rel in drop.files {
            // Reject path traversal: the host only ever sends "<batch>/<name>".
            let parts = rel.split(separator: "/")
            guard parts.count == 2, !parts.contains(where: { $0 == ".." || $0 == "." }) else { continue }
            let src = transferRoot.appendingPathComponent(String(parts[0])).appendingPathComponent(String(parts[1]))
            batches.insert(String(parts[0]))
            let dest = uniqueURL(desktop.appendingPathComponent(String(parts[1])))
            do {
                try fm.copyItem(at: src, to: dest)
                placed.append(dest)
            } catch {
                log("drop: could not copy \(parts[1]): \(error.localizedDescription)")
            }
        }
        for b in batches { try? fm.removeItem(at: transferRoot.appendingPathComponent(b)) }
        if !placed.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(placed)
            log("drop: placed \(placed.count) file(s) on the Desktop")
        }
    }

    static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        for i in 2... {
            let name = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            let candidate = url.deletingLastPathComponent().appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}
