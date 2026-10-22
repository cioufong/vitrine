import Foundation

public extension VMBundle {
    /// Removes or trashes a stopped package while retaining its ownership lock. Moving it out of
    /// the library first prevents later find/start operations from opening the package being deleted.
    /// acquireRunLock also rejects a contender that opened the old lock inode before this move.
    func deleteSafely(trash: Bool = false) throws {
        try withExclusiveLock {
            let fm = FileManager.default
            let retired = url.deletingLastPathComponent().appendingPathComponent(".vitrine-delete-\(UUID().uuidString)")
            try fm.moveItem(at: url, to: retired)
            do {
                if trash { try fm.trashItem(at: retired, resultingItemURL: nil) }
                else { try fm.removeItemForcibly(at: retired) }
            } catch {
                // Preserve the recoverable package if deletion fails. Never overwrite a new VM
                // that another creator has meanwhile installed under the old name.
                if !fm.fileExists(atPath: url.path) { try? fm.moveItem(at: retired, to: url) }
                throw error
            }
        }
    }
}
