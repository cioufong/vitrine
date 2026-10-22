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
    /// - Returns: whether the run's changes were discarded.
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
        try discard()
        return true
    }

    /// Restores the recorded baseline and forgets it.
    func discard() throws {
        var marker = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: markerURL))
        if marker.restored != true {
            try store.restore(marker.snapshot)
            // Recovery must not need the snapshot once cleanup starts deleting it.
            marker.restored = true
            try JSONEncoder().encode(marker).write(to: markerURL, options: .atomic)
        }
        try finishCleanup(marker)
    }

    private func finishCleanup(_ marker: Marker) throws {
        let snapshotURL = bundle.url.appendingPathComponent("snapshots/\(marker.snapshot.uuidString)")
        if FileManager.default.fileExists(atPath: snapshotURL.path) { try store.delete(marker.snapshot) }
        try FileManager.default.removeItem(at: markerURL)
    }
}
