import Foundation

public extension FileManager {
    /// Adds owner write permission throughout a tree. Files copied off read-only media (the
    /// virtio-win ISO) keep `r-x` directories, and their contents can't be deleted until fixed.
    func makeWritable(_ url: URL) {
        func fix(_ path: String) {
            guard let attrs = try? attributesOfItem(atPath: path),
                  let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value else { return }
            if mode & 0o200 == 0 { try? setAttributes([.posixPermissions: mode | 0o200], ofItemAtPath: path) }
        }
        fix(url.path)
        guard let walker = enumerator(atPath: url.path) else { return }
        for case let rel as String in walker { fix(url.appendingPathComponent(rel).path) }
    }

    /// Removes a tree even when parts of it are read-only.
    func removeItemForcibly(at url: URL) throws {
        guard fileExists(atPath: url.path) else { return }
        makeWritable(url)
        try removeItem(at: url)
    }
}
