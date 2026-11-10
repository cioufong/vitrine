import Foundation

/// Disposable mode: the VM runs on top of a baseline snapshot (APFS clones, so instant and nearly
/// free) that is restored when it stops, discarding everything the run changed — disks, NVRAM,
/// TPM and configuration. All calls require the caller to hold the bundle's run lock.
public struct DisposableSession {
    public let bundle: VMBundle

    public init(bundle: VMBundle) { self.bundle = bundle }

    var markerURL: URL { bundle.url.appendingPathComponent("disposable-session.json") }
    static let snapshotName = "Disposable session (restored when the VM stops)"

    private struct Marker: Codable { var snapshot: UUID; var restored: Bool? }

    /// A previous disposable run that never finished (crash, power loss) is still pending.
    public var isPending: Bool { FileManager.default.fileExists(atPath: markerURL.path) }

    /// The snapshot a pending run is rolled back to, until that rollback has completed (nil when
    /// no run is pending). It is the only copy of the pre-run state, so it can't be deleted.
    public var baselineSnapshotID: UUID? {
        guard let data = try? Data(contentsOf: markerURL),
              let marker = try? JSONDecoder().decode(Marker.self, from: data), marker.restored != true else { return nil }
        return marker.snapshot
    }

    private var store: SnapshotStore { SnapshotStore(bundle: bundle, lockHeldByCaller: true) }

    /// Before a disposable VM starts: rolls back an unfinished earlier run, then records the
    /// baseline the coming run is discarded back to.
    public func begin() throws {
        if isPending { try discard() }
        if bundle.hasSavedState {
            throw VitrineError.invalidConfig("disposable mode needs a shut-down VM; discard its suspended state first")
        }
        let snap = try store.create(name: Self.snapshotName)
        do {
            try JSONEncoder().encode(Marker(snapshot: snap.id)).write(to: markerURL, options: .atomic)
        } catch {
            try? store.delete(snap.id)
            throw error
        }
    }

    /// After the run: restores the baseline, unless disposable mode was switched off during the
    /// run (then the run's changes are kept), and removes the baseline.
    /// - Returns: whether the run's changes were discarded (false also when its baseline was
    ///   missing, so there was nothing to roll back to).
    @discardableResult
    public func end() throws -> Bool {
        guard isPending else { return false }
        let keep = (try? bundle.loadConfig())?.features.disposable == false
        if keep {
            var marker = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: markerURL))
            marker.restored = true
            try JSONEncoder().encode(marker).write(to: markerURL, options: .atomic)
            try finishCleanup(marker)
            return false
        }
        return try discard()
    }

    /// Restores the recorded baseline and forgets it.
    /// - Returns: false when the baseline was missing and nothing was restored.
    @discardableResult
    func discard() throws -> Bool {
        var marker = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: markerURL))
        if marker.restored != true, !FileManager.default.fileExists(atPath: snapshotURL(marker).path) {
            // Deleted by an older version or by hand: there is nothing to roll back to. Failing here
            // would fail every later start, so keep the current state and forget the run.
            appendToVMLog("disposable run: its baseline snapshot is missing, so there is nothing to roll back; keeping the VM's current state")
            try FileManager.default.removeItem(at: markerURL)
            return false
        }
        if marker.restored != true {
            try store.restore(marker.snapshot)
            // Recovery must not need the snapshot once cleanup starts deleting it.
            marker.restored = true
            try JSONEncoder().encode(marker).write(to: markerURL, options: .atomic)
        }
        try finishCleanup(marker)
        return true
    }

    private func snapshotURL(_ marker: Marker) -> URL {
        bundle.url.appendingPathComponent("snapshots/\(marker.snapshot.uuidString)")
    }

    private func finishCleanup(_ marker: Marker) throws {
        if FileManager.default.fileExists(atPath: snapshotURL(marker).path) {
            try store.delete(marker.snapshot, allowingDisposableBaseline: true)
        }
        try FileManager.default.removeItem(at: markerURL)
    }

    /// Same file and line format as the VM controller's log.
    private func appendToVMLog(_ line: String) {
        let text = Data("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: bundle.logURL) {
            _ = try? h.seekToEnd(); try? h.write(contentsOf: text); try? h.close()
        } else {
            try? text.write(to: bundle.logURL)
        }
    }
}
