import Foundation

public extension VMBundle {
    /// Removes or trashes a stopped package while retaining its ownership lock. When removing, moving
    /// it out of the library first prevents later find/start operations from opening the package being deleted.
    /// acquireRunLock also rejects a contender that opened the old lock inode before this move.
    /// Trashing keeps the package's name, so it can be found in the Trash and put back; the move
    /// to the Trash is itself what takes it out of the library. Returns where it went.
    @discardableResult
    func deleteSafely(trash: Bool = false) throws -> URL? {
        try withExclusiveLock {
            let fm = FileManager.default
            if trash {
                var trashed: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &trashed)
                return trashed as URL?
            }
            let retired = url.deletingLastPathComponent().appendingPathComponent(".vitrine-delete-\(UUID().uuidString)")
            try fm.moveItem(at: url, to: retired)
            do {
                try fm.removeItemForcibly(at: retired)
            } catch {
                // Preserve the recoverable package if deletion fails. Never overwrite a new VM
                // that another creator has meanwhile installed under the old name.
                if !fm.fileExists(atPath: url.path) { try? fm.moveItem(at: retired, to: url) }
                throw error
            }
            return nil
        }
    }
}
