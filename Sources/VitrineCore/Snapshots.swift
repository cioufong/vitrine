import Foundation

/// A point-in-time copy of a VM's disks, NVRAM/aux storage and config — and, when the VM was
/// suspended, its memory state. Built from APFS clones, so taking one is instant and costs no space
/// until the VM writes new data.
public struct Snapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    /// Includes a saved machine state (VM was suspended when the snapshot was taken).
    public var includesMemory: Bool
    /// Files captured, relative to the bundle.
    public var files: [String]
}

public struct SnapshotStore: Sendable {
    public let bundle: VMBundle
    private let makeFileManager: @Sendable () -> FileManager
    /// The caller already holds this bundle's run lock (disposable sessions, around a VM run).
    private let lockHeldByCaller: Bool

    public init(bundle: VMBundle, fileManagerFactory: @escaping @Sendable () -> FileManager = { .default }) {
        self.bundle = bundle
        self.makeFileManager = fileManagerFactory
        self.lockHeldByCaller = false
    }

    init(bundle: VMBundle, lockHeldByCaller: Bool) {
        self.bundle = bundle
        self.makeFileManager = { .default }
        self.lockHeldByCaller = lockHeldByCaller
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        if lockHeldByCaller {
            guard bundle.holdsRunLock else { throw VitrineError.backend("snapshot operation needs the VM lock") }
            return try body()
        }
        return try bundle.withExclusiveLock(body)
    }

    private func directory(for id: UUID) -> URL {
        bundle.snapshotsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Machine-state files that hold guest RAM. Exactly the ones captured in a snapshot may exist
    /// after restoring it: a newer save must never be loaded against reverted disks.
    /// The USB marker (was the state saved with an xHCI controller?) and the attachments to plug
    /// back in belong to the saved RAM and must live and die with it.
    static let memoryFiles = ["state.vzvmsave", "state.qemusave", "state.usb", "usb-attachments.json"]

    private static let persistentFiles = ["config.json", "aux-storage.bin", "hardware-model.bin",
        "machine-identifier.bin", "nvram.bin", "efivars.fd", "efivars.secureboot", "tpm"]

    /// Snapshot entries are canonical bundle-relative names, never filesystem aliases. In
    /// particular, a symlink inside a TPM directory must not smuggle uncaptured state into RAM.
    private static func isRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.hasPrefix("~") && !path.contains("\0")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }

    private static func isDiskPath(_ path: String) -> Bool {
        guard isRelativePath(path), let first = path.split(separator: "/").first else { return false }
        let name = first.lowercased() // APFS commonly compares these names without case.
        return !Set(persistentFiles + memoryFiles + ["snapshots", "snapshot.json", "run.lock", "guest-account.secret"])
            .contains(name) && !name.hasPrefix(".restore-")
    }

    /// Checks every existing ancestor, even for a missing destination. Do not follow symlinks:
    /// replacing one would otherwise write through an alias or change its meaning on restore.
    fileprivate static func validatePath(_ path: String, in root: URL, recursive: Bool = false) throws {
        guard isRelativePath(path) else { throw VitrineError.invalidConfig("unsafe snapshot path: \(path)") }
        let fm = FileManager.default
        var url = root
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
            do {
                let type = try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
                guard type == .typeRegular || type == .typeDirectory else {
                    throw VitrineError.invalidConfig("snapshot state must not contain symlinks or special files: \(url.path)")
                }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                // Missing files may be valid restore destinations. Required sources are checked separately.
                break
            }
        }
        if recursive, fm.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    try validatePath(path + "/" + child.lastPathComponent, in: root, recursive: true)
                }
            }
        }
    }

    /// Read-only external media remain references. Every writable configured disk must instead
    /// be a real file in this bundle and appear in the manifest, including old snapshots.
    private static func diskFiles(config: VMConfig) throws -> [String] {
        for disk in config.disks where !disk.readOnly && !isDiskPath(disk.path) {
            throw VitrineError.unsupported("\(disk.path) is not a safe bundle-relative writable disk; use a bundle-relative path to a disk inside the VM bundle or make it read-only before taking snapshots or cloning")
        }
        return (config.disks.map(\.path) + (config.extraMedia ?? []) + [config.installMedia].compactMap { $0 })
            .filter { isDiskPath($0) }
    }

    private static func validateMemory(files: Set<String>, includesMemory: Bool, in root: URL) throws {
        let ram = files.intersection(["state.vzvmsave", "state.qemusave"])
        guard ram.count <= 1, includesMemory == !ram.isEmpty,
              includesMemory || files.isDisjoint(with: memoryFiles) else {
            throw VitrineError.invalidConfig("snapshot memory metadata does not match its saved state")
        }
        // A manifest must not silently omit saved RAM or its USB metadata present in the snapshot.
        for file in memoryFiles {
            let exists = FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path)
            guard exists == files.contains(file) else {
                throw VitrineError.invalidConfig("snapshot manifest omits or is missing \(file)")
            }
            if exists {
                let type = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(file).path)[.type] as? FileAttributeType
                guard type == .typeRegular else {
                    throw VitrineError.invalidConfig("snapshot memory state must be a regular file: \(file)")
                }
            }
        }
        if files.contains("usb-attachments.json") {
            let attachments = try JSONDecoder().decode([USBAttachment].self,
                from: Data(contentsOf: root.appendingPathComponent("usb-attachments.json")))
            for attachment in attachments {
                switch attachment {
                case .image(_, readOnly: true): break
                default:
                    // Hot-plug attachments use host paths/device identities, not bundle-relative
                    // disk configuration. Their mutable state cannot be rolled back safely.
                    throw VitrineError.unsupported("saved USB writable images and host devices cannot be snapshotted; shut down the VM or detach them before suspending")
                }
            }
        }
    }

    fileprivate func captureFiles(config: VMConfig, includeMemory: Bool = true) throws -> [String] {
        let fm = FileManager.default
        let disks = try Self.diskFiles(config: config)
        for disk in config.disks where !disk.readOnly {
            try Self.validatePath(disk.path, in: bundle.url)
            let attrs = try fm.attributesOfItem(atPath: bundle.resolve(disk.path).path)
            guard attrs[.type] as? FileAttributeType == .typeRegular else {
                throw VitrineError.invalidConfig("writable disk is not a regular file: \(disk.path)")
            }
        }
        var files: [String] = []
        for file in disks + Self.persistentFiles + (includeMemory ? Self.memoryFiles : []) {
            // External read-only symlinks are references, just like absolute read-only media.
            if disks.contains(file), !config.disks.contains(where: { $0.path == file && !$0.readOnly }),
               (try? Self.validatePath(file, in: bundle.url, recursive: true)) == nil { continue }
            try Self.validatePath(file, in: bundle.url, recursive: true)
            if fm.fileExists(atPath: bundle.resolve(file).path), !files.contains(file) { files.append(file) }
        }
        try Self.validateEntries(files)
        if includeMemory {
            try Self.validateMemory(files: Set(files), includesMemory: files.contains("state.vzvmsave") || files.contains("state.qemusave"), in: bundle.url)
            try Self.validatePath("snapshots", in: bundle.url)
        }
        return files
    }

    private static func validateEntries(_ files: [String]) throws {
        guard Set(files).count == files.count, files.contains("config.json") else {
            throw VitrineError.invalidConfig("snapshot manifest must contain config.json and unique file entries")
        }
        for file in files {
            guard isRelativePath(file), !files.contains(where: { file.hasPrefix($0 + "/") }) else {
                throw VitrineError.invalidConfig("unsafe or overlapping snapshot entry: \(file)")
            }
        }
    }

    private func validate(_ snapshot: Snapshot, in dir: URL) throws {
        try Self.validateEntries(snapshot.files)
        try Self.validatePath("config.json", in: dir)
        let config = try VMBundle(url: dir).loadConfig()
        let allowed = Set(try Self.diskFiles(config: config) + Self.persistentFiles + Self.memoryFiles)
        let files = Set(snapshot.files)
        guard files.isSubset(of: allowed), config.disks.filter({ !$0.readOnly }).allSatisfy({ files.contains($0.path) }) else {
            throw VitrineError.invalidConfig("snapshot manifest contains unexpected entries or omits a writable disk")
        }
        for file in snapshot.files {
            try Self.validatePath(file, in: dir, recursive: true)
            try Self.validatePath(file, in: bundle.url, recursive: true)
            guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path) else {
                throw VitrineError.fileNotFound("snapshot file \(file)")
            }
        }
        for disk in config.disks where !disk.readOnly {
            let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(disk.path).path)
            guard attrs[.type] as? FileAttributeType == .typeRegular else {
                throw VitrineError.invalidConfig("snapshot writable disk is not a regular file: \(disk.path)")
            }
        }
        try Self.validateMemory(files: files, includesMemory: snapshot.includesMemory, in: dir)
    }

    public func list() -> [Snapshot] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: bundle.snapshotsDirectory, includingPropertiesForKeys: nil)
        else { return [] }
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("snapshot.json")) else { return nil }
            return try? Self.decoder.decode(Snapshot.self, from: data)
        }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Takes a snapshot. The VM must be stopped or suspended (state saved) so disks are consistent;
    /// the bundle lock is held throughout so it can't be started meanwhile. External read-only
    /// media and shared host directories remain references; their contents are not captured.
    @discardableResult
    public func create(name: String) throws -> Snapshot {
        try locked {
            let config = try bundle.loadConfig()
            let files = try captureFiles(config: config)
            let snap = Snapshot(id: UUID(), name: name, createdAt: Date(),
                                includesMemory: files.contains { $0 == "state.vzvmsave" || $0 == "state.qemusave" }, files: files)
            let dir = directory(for: snap.id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            do {
                for file in files {
                    let dst = dir.appendingPathComponent(file)
                    try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try DiskImage.clone(bundle.resolve(file), to: dst)
                }
                try Self.encoder.encode(snap).write(to: dir.appendingPathComponent("snapshot.json"))
            } catch {
                try? FileManager.default.removeItem(at: dir)
                throw error
            }
            return snap
        }
    }

    /// Identifies the staged item across a rename, and notices replacement or in-place writes
    /// before rollback touches it. A new destination belongs to whoever created it.
    private struct RestoreFileStamp: Equatable {
        var device: Int64
        var inode: UInt64
        var size: Int64
        var modifiedSeconds: Int
        var modifiedNanoseconds: Int

        static func read(_ url: URL) throws -> RestoreFileStamp? {
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                if errno == ENOENT { return nil }
                throw VitrineError.io("cannot inspect \(url.path): \(String(cString: strerror(errno)))")
            }
            return RestoreFileStamp(device: Int64(info.st_dev), inode: UInt64(info.st_ino), size: info.st_size,
                modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec)
        }
    }

    /// Reverts the VM to a snapshot; current state is discarded. Current files are moved aside
    /// first and put back on failure. If rollback also fails, retain recovery files and report
    /// their location rather than deleting the only original copy.
    public func restore(_ id: UUID) throws {
        try locked {
            let fm = makeFileManager()
            if let recovery = try fm.contentsOfDirectory(at: bundle.url, includingPropertiesForKeys: nil)
                .first(where: { $0.lastPathComponent.hasPrefix(".restore-") }) {
                throw VitrineError.io("unfinished snapshot restore at \(recovery.path); recover its original files before retrying or starting the VM")
            }
            let dir = directory(for: id)
            try Self.validatePath("snapshots/\(id.uuidString)/snapshot.json", in: bundle.url)
            let snap = try Self.decoder.decode(Snapshot.self, from: Data(contentsOf: dir.appendingPathComponent("snapshot.json")))
            guard snap.id == id else { throw VitrineError.invalidConfig("snapshot ID does not match its directory") }
            try validate(snap, in: dir)
            // The Secure Boot marker records which keys efivars.fd holds; it must not outlive them.
            let staleState = Self.memoryFiles + ["tpm", "efivars.fd", "efivars.secureboot"]
            for file in staleState { try Self.validatePath(file, in: bundle.url, recursive: true) }
            let work = bundle.url.appendingPathComponent(".restore-\(UUID().uuidString)", isDirectory: true)
            let staged = work.appendingPathComponent("new", isDirectory: true)
            let backup = work.appendingPathComponent("old", isDirectory: true)
            try fm.createDirectory(at: staged, withIntermediateDirectories: true)
            try fm.createDirectory(at: backup, withIntermediateDirectories: true)
            var preserveRecoveryFiles = false
            defer { if !preserveRecoveryFiles { try? fm.removeItem(at: work) } }

            // 1. Clone the snapshot's files next to the bundle (same volume, so moves are atomic).
            for file in snap.files {
                let dst = staged.appendingPathComponent(file)
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try DiskImage.clone(dir.appendingPathComponent(file), to: dst)
            }
            // 2. Move every current state file aside: the snapshot's files, plus saved RAM (and
            //    TPM/EFI state) the snapshot doesn't have, which must not survive the restore.
            let toReplace = Set(snap.files).union(staleState.filter { fm.fileExists(atPath: bundle.resolve($0).path) })
            var movedAside: [String] = []
            var installed: [(file: String, stamp: RestoreFileStamp)] = []
            do {
                for file in toReplace where fm.fileExists(atPath: bundle.resolve(file).path) {
                    let dst = backup.appendingPathComponent(file)
                    try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: bundle.resolve(file), to: dst)
                    movedAside.append(file)
                }
                // 3. Move the snapshot's files into place.
                for file in snap.files {
                    let target = bundle.resolve(file)
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let source = staged.appendingPathComponent(file)
                    guard let stamp = try RestoreFileStamp.read(source) else { throw VitrineError.fileNotFound(source.path) }
                    try fm.moveItem(at: source, to: target)
                    installed.append((file, stamp))
                }
            } catch {
                let restoreError = error
                var rollbackErrors: [String] = []
                // Move our installed copies back into staging; never remove a destination that
                // someone replaced/changed meanwhile. Keep these copies until recovery succeeds.
                for (file, stamp) in installed.reversed() {
                    do {
                        try Self.validatePath(file, in: bundle.url)
                        let target = bundle.resolve(file)
                        if let current = try RestoreFileStamp.read(target) {
                            guard current == stamp else { throw VitrineError.io("destination changed: \(target.path)") }
                            try fm.moveItem(at: target, to: staged.appendingPathComponent(file))
                        }
                    } catch { rollbackErrors.append("\(file): \(error.localizedDescription)") }
                }
                for file in movedAside.reversed() {
                    do {
                        try Self.validatePath(file, in: bundle.url)
                        let target = bundle.resolve(file)
                        guard try RestoreFileStamp.read(target) == nil else {
                            throw VitrineError.io("recovery destination already exists: \(target.path)")
                        }
                        // FileManager.moveItem refuses an existing target; do not replace a new
                        // destination even if it appeared after the check above.
                        try fm.moveItem(at: backup.appendingPathComponent(file), to: target)
                    } catch { rollbackErrors.append("\(file): \(error.localizedDescription)") }
                }
                if !rollbackErrors.isEmpty {
                    preserveRecoveryFiles = true
                    throw VitrineError.io("snapshot restore failed: \(restoreError.localizedDescription). Rollback incomplete: \(rollbackErrors.joined(separator: "; ")). Recovery files retained at \(work.path); original files remain at \(backup.path). Recover them before retrying or starting the VM")
                }
                throw restoreError
            }
        }
    }

    public func delete(_ id: UUID) throws {
        try locked {
            try Self.validatePath("snapshots/\(id.uuidString)", in: bundle.url)
            let dir = directory(for: id)
            guard FileManager.default.fileExists(atPath: dir.path) else { throw VitrineError.fileNotFound("snapshot \(id)") }
            try FileManager.default.removeItem(at: dir)
        }
    }

    /// Finds a snapshot by UUID string or by name.
    public func find(_ key: String) -> Snapshot? {
        list().first { $0.id.uuidString.lowercased() == key.lowercased() || $0.name == key }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}

/// Full copy of a VM with a fresh identity. Disks are APFS clones.
public enum VMCloner {
    public static func clone(_ source: VMBundle, to dest: URL, newName: String) throws -> VMBundle {
        try source.withExclusiveLock {
            var config = try source.loadConfig()
            // Validate all source state before creating even the destination's parent. A writable
            // symlink or ../ path would otherwise leave the clone sharing or escaping its bundle.
            var files = try SnapshotStore(bundle: source).captureFiles(config: config, includeMemory: false)
                .filter { $0 != "config.json" && $0 != "machine-identifier.bin" }
            try SnapshotStore.validatePath("guest-account.secret", in: source.url, recursive: true)
            files.append("guest-account.secret")
            // Relative external read-only aliases must keep referring to the same host media after
            // the clone moves to another directory. They are references rather than captured files.
            func readOnlyReference(_ path: String) -> String {
                files.contains(path) ? path : source.resolve(path).resolvingSymlinksInPath().path
            }
            for index in config.disks.indices where config.disks[index].readOnly {
                config.disks[index].path = readOnlyReference(config.disks[index].path)
            }
            config.extraMedia = config.extraMedia?.map(readOnlyReference)
            config.installMedia = config.installMedia.map(readOnlyReference)
            let fm = FileManager.default
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard mkdir(dest.path, 0o700) == 0 else { throw VitrineError.io("\(dest.path) already exists") }
            let out = VMBundle(url: dest)
            do {
                // Disks and media inside the bundle, platform identity/NVRAM, EFI variables and the
                // TPM (a clone without it would fail BitLocker/TPM-sealed secrets), credentials.
                for f in files where fm.fileExists(atPath: source.resolve(f).path) {
                    let dst = out.resolve(f)
                    try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try DiskImage.clone(source.resolve(f), to: dst)
                }
                // machine-identifier.bin is intentionally not copied: the backend generates a new one,
                // since two VMs with the same identifier must never run together.
                // The cloned disk keeps announcing the source's host name until the guest changes it.
                config.guestHostname = config.dhcpHostname
                config.id = UUID()
                config.name = newName
                config.network.macAddress = randomMACAddress()
                try out.saveConfig(config)
            } catch {
                try? fm.removeItem(at: dest)
                throw error
            }
            return out
        }
    }
}
