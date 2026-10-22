import Foundation

/// On-disk VM package: `<name>.vitrinevm/`.
public struct VMBundle: Sendable, Hashable {
    public static let pathExtension = "vitrinevm"

    public let url: URL

    public init(url: URL) { self.url = url.standardizedFileURL }

    public var name: String { url.deletingPathExtension().lastPathComponent }
    public var configURL: URL { url.appendingPathComponent("config.json") }
    public var machineIdentifierURL: URL { url.appendingPathComponent("machine-identifier.bin") }
    public var hardwareModelURL: URL { url.appendingPathComponent("hardware-model.bin") }
    public var auxiliaryStorageURL: URL { url.appendingPathComponent("aux-storage.bin") }
    public var savedStateURL: URL { url.appendingPathComponent("state.vzvmsave") }
    /// Present next to a VZ saved state that was made with an xHCI controller (states saved by
    /// older Vitrine versions have none, and VZ only restores into a matching configuration).
    public var savedStateUSBMarkerURL: URL { url.appendingPathComponent("state.usb") }
    /// USB drives/devices attached when the VM was suspended; plugged in again on resume.
    public var suspendedUSBURL: URL { url.appendingPathComponent("usb-attachments.json") }
    /// Secret the host presents in its Hello to agents reachable over TCP (Windows on QEMU), which
    /// read it from SMBIOS OEM strings. Mode 0600.
    public var agentTokenURL: URL { url.appendingPathComponent("agent.token") }
    /// UEFI variable store (Linux guests).
    public var nvramURL: URL { url.appendingPathComponent("nvram.bin") }
    /// Serial console output (Linux guests).
    public var consoleLogURL: URL { url.appendingPathComponent("console.log") }
    public var cacheDirectory: URL { url.appendingPathComponent("cache", isDirectory: true) }
    /// QEMU: UEFI variable store copied from the firmware template on first start.
    public var efiVarsURL: URL { url.appendingPathComponent("efivars.fd") }
    /// QEMU: swtpm state (TPM 2.0 for Windows 11).
    public var tpmStateDirectory: URL { url.appendingPathComponent("tpm", isDirectory: true) }
    /// QEMU: saved machine state for suspend/resume.
    public var qemuStateURL: URL { url.appendingPathComponent("state.qemusave") }
    public var qemuLogURL: URL { url.appendingPathComponent("qemu.log") }
    /// Short-lived sockets (QMP, VNC, agent, TPM). Kept under /tmp: AF_UNIX paths are limited to 104 bytes.
    public var socketDirectory: URL {
        // Stable across processes (Swift's hashValue is randomized per launch): FNV-1a of the path.
        var h: UInt64 = 0xcbf29ce484222325
        for b in url.path.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vitrine-\(String(h, radix: 36))", isDirectory: true)
    }
    public var snapshotsDirectory: URL { url.appendingPathComponent("snapshots", isDirectory: true) }
    public var logURL: URL { url.appendingPathComponent("vitrine.log") }
    /// Last screen of the VM, shown in Control Center.
    public var thumbnailURL: URL { url.appendingPathComponent("thumbnail.png") }
    /// Shared with the guest as "Vitrine Transfer" for drag-and-drop.
    public var transferDirectory: URL { url.appendingPathComponent("transfer", isDirectory: true) }
    /// Present while a process owns the VM; contains its PID.
    public var lockURL: URL { url.appendingPathComponent("run.lock") }

    /// Whether the VM is suspended: a saved state from either backend is waiting to be resumed.
    public var hasSavedState: Bool {
        FileManager.default.fileExists(atPath: savedStateURL.path) || FileManager.default.fileExists(atPath: qemuStateURL.path)
    }

    /// Deletes the suspended state (memory, USB marker, drives to plug back in), so the next start
    /// boots from disk.
    public func discardSavedState() {
        for file in [savedStateURL, qemuStateURL, savedStateUSBMarkerURL, suspendedUSBURL] {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Resolves a config path: absolute paths stay as-is, relative ones are bundle-relative.
    public func resolve(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        return url.appendingPathComponent(expanded)
    }

    public func loadConfig() throws -> VMConfig {
        let data: Data
        do { data = try Data(contentsOf: configURL) } catch {
            throw VitrineError.fileNotFound(configURL.path)
        }
        let config: VMConfig
        do { config = try JSONDecoder().decode(VMConfig.self, from: data) } catch {
            throw VitrineError.invalidConfig("cannot parse \(configURL.path): \(error)")
        }
        if config.version > VMConfig.currentVersion {
            throw VitrineError.unsupported("config version \(config.version) is newer than this Vitrine build")
        }
        return config
    }

    public func saveConfig(_ config: VMConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try data.write(to: configURL, options: .atomic)
    }

    /// Creates a new bundle directory with the given config. Fails if it already exists.
    @discardableResult
    public static func create(at url: URL, config: VMConfig) throws -> VMBundle {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // mkdir is atomic: of two concurrent creators with the same name, exactly one succeeds.
        guard mkdir(url.path, 0o700) == 0 else { // private: holds the guest password and seed media
            if errno == EEXIST { throw VitrineError.io("\(url.path) already exists") }
            throw VitrineError.io("cannot create \(url.path): \(String(cString: strerror(errno)))")
        }
        let bundle = VMBundle(url: url)
        do { try bundle.saveConfig(config) } catch {
            try? fm.removeItem(at: url) // the directory made just above
            throw error
        }
        return bundle
    }

    /// Creates a new bundle, lets `populate` add its files and finish the config, then saves the
    /// config. If anything fails, the half-made bundle is deleted.
    @discardableResult
    public static func create(at url: URL, config: VMConfig,
                              populate: (VMBundle, inout VMConfig) throws -> Void) throws -> VMBundle {
        let bundle = try create(at: url, config: config)
        var config = config
        do {
            try populate(bundle, &config)
            try bundle.saveConfig(config)
        } catch {
            try? FileManager.default.removeItemForcibly(at: url) // may hold files copied off read-only media
            throw error
        }
        return bundle
    }

    /// `create(at:config:populate:)` for a `populate` that awaits (downloads, extraction).
    @discardableResult
    public static func create(at url: URL, config: VMConfig,
                              populate: (VMBundle, inout VMConfig) async throws -> Void) async throws -> VMBundle {
        let bundle = try create(at: url, config: config)
        var config = config
        do {
            try await populate(bundle, &config)
            try bundle.saveConfig(config)
        } catch {
            try? FileManager.default.removeItemForcibly(at: url)
            throw error
        }
        return bundle
    }

    /// Creates the VM's main disk and returns its file name: `disk.asif`, or `disk.img` for a raw
    /// image (including an ASIF request that fell back to raw, so the extension tells the truth).
    public func createMainDisk(sizeBytes: UInt64, format: DiskImageFormat) throws -> String {
        let name = format == .asif ? "disk.asif" : "disk.img"
        guard try DiskImage.create(at: resolve(name), sizeBytes: sizeBytes, format: format) != format else { return name }
        try FileManager.default.moveItem(at: resolve(name), to: resolve("disk.img"))
        return "disk.img"
    }

    // MARK: Ownership lock

    /// Who holds a bundle's lock: a VM run by Vitrine.app or `vitrinectl run`, or a short
    /// maintenance operation (snapshot, clone, restore).
    public enum LockRole: String, Sendable { case app, cli, operation }
    public struct LockOwner: Equatable, Sendable { public var pid: pid_t; public var role: LockRole }

    /// Role recorded when this process runs a VM. Vitrine.app sets `.app` at launch.
    nonisolated(unsafe) public static var processRole: LockRole = .cli

    /// Takes the bundle's exclusive lock (flock, so the kernel releases it if the process dies).
    /// Running a VM holds it for the VM's lifetime; snapshot/clone/restore hold it briefly.
    public func acquireRunLock(role: LockRole? = nil) throws {
        let key = lockURL.path
        if BundleLocks.shared.fd(for: key) != nil {
            throw VitrineError.backend("VM \(name) is already in use by this process")
        }
        let fd = open(key, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw VitrineError.io("cannot open \(key): \(String(cString: strerror(errno)))") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            let owner = lockOwner()
            let what = owner?.role == .operation ? "busy (snapshot or clone in progress)" : "already running"
            throw VitrineError.backend("VM \(name) is \(what)\(owner.map { " (pid \($0.pid))" } ?? "")")
        }
        // A deletion may have renamed the bundle after open() but before flock(). An orphaned
        // inode is not ownership of the VM now at this path (and must never recreate its files).
        var held = stat(), current = stat()
        guard fstat(fd, &held) == 0, lstat(key, &current) == 0,
              held.st_dev == current.st_dev, held.st_ino == current.st_ino,
              current.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            throw VitrineError.backend("VM \(name) moved or was deleted while acquiring its lock; retry")
        }
        let effectiveRole = role ?? Self.processRole
        if effectiveRole != .operation {
            let recovery: URL?
            do {
                recovery = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    .first { $0.lastPathComponent.hasPrefix(".restore-") }
            } catch {
                close(fd)
                throw VitrineError.io("cannot check snapshot recovery in \(url.path): \(error.localizedDescription)")
            }
            if let recovery {
                close(fd)
                throw VitrineError.backend("VM \(name) has unfinished snapshot recovery at \(recovery.path); recover its original files before starting the VM")
            }
        }
        let text = "\(getpid()) \(effectiveRole.rawValue)\n"
        ftruncate(fd, 0)
        _ = text.withCString { pwrite(fd, $0, strlen($0), 0) }
        BundleLocks.shared.set(fd, for: key)
    }

    /// Runs file edits under the exclusive bundle lock. Running VMs must edit through their owner.
    public func withExclusiveLockIfStopped(_ body: () throws -> Void) throws {
        try withExclusiveLock(body)
    }

    /// Whether this process currently holds the run lock.
    public var holdsRunLock: Bool { BundleLocks.shared.fd(for: lockURL.path) != nil }

    public func releaseRunLock() {
        guard let fd = BundleLocks.shared.take(lockURL.path) else { return }
        ftruncate(fd, 0)
        close(fd) // drops the flock
    }

    /// Runs `body` while holding the bundle lock, so the VM can't be started (or modified by
    /// another process) halfway through.
    public func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        try acquireRunLock(role: .operation)
        defer { releaseRunLock() }
        return try body()
    }

    /// The live holder of the lock, or nil when nobody holds it (stale files are ignored).
    public func lockOwner() -> LockOwner? {
        let key = lockURL.path
        if BundleLocks.shared.fd(for: key) != nil { return LockOwner(pid: getpid(), role: Self.processRole) }
        let fd = open(key, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 { flock(fd, LOCK_UN); return nil }
        // Locked: the holder writes its pid right after locking; allow it a moment.
        for _ in 0..<20 {
            var buf = [UInt8](repeating: 0, count: 64)
            let n = pread(fd, &buf, 63, 0)
            let parts = n > 0 ? String(decoding: buf[0..<n], as: UTF8.self).split(whereSeparator: \.isWhitespace) : []
            if let first = parts.first, let pid = pid_t(first), pid > 1 {
                let role = parts.count > 1 ? LockRole(rawValue: String(parts[1])) ?? .cli : .cli
                return LockOwner(pid: pid, role: role)
            }
            usleep(10_000)
        }
        return nil
    }

    /// PID of the live process holding the lock, or nil.
    public func runningPID() -> pid_t? { lockOwner()?.pid }

    /// The VM's agent token (64 hex digits), created on first use.
    public func agentToken() throws -> String {
        if let s = try? String(contentsOf: agentTokenURL, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count == 64, t.allSatisfy(\.isHexDigit) { return t }
        }
        // SystemRandomNumberGenerator is the kernel CSPRNG (arc4random) on Darwin and can't fail.
        var rng = SystemRandomNumberGenerator()
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &rng)) }.joined()
        let fd = open(agentTokenURL.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw VitrineError.invalidConfig("can't write \(agentTokenURL.path)") }
        defer { close(fd) }
        fchmod(fd, 0o600)
        guard write(fd, token, token.utf8.count) == token.utf8.count else {
            throw VitrineError.invalidConfig("can't write \(agentTokenURL.path)")
        }
        return token
    }

    /// True while any process holds the lock, even if its pid could not be read.
    public var isLocked: Bool {
        if BundleLocks.shared.fd(for: lockURL.path) != nil { return true }
        let fd = open(lockURL.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
        return true
    }
}

/// Default location for VMs: ~/Library/Application Support/Vitrine/VMs (overridable with VITRINE_HOME).
public enum VMLibrary {
    public static var root: URL {
        if let custom = ProcessInfo.processInfo.environment["VITRINE_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Vitrine/VMs", isDirectory: true)
    }

    /// Shared cache for restore images.
    public static var cacheDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["VITRINE_CACHE"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Vitrine", isDirectory: true)
    }

    public static func bundleURL(named name: String) -> URL {
        root.appendingPathComponent("\(name).\(VMBundle.pathExtension)", isDirectory: true)
    }

    public static func list() -> [VMBundle] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { $0.pathExtension == VMBundle.pathExtension }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map(VMBundle.init(url:))
    }

    /// Finds a VM by bundle name or by path.
    public static func find(_ nameOrPath: String) throws -> VMBundle {
        let expanded = (nameOrPath as NSString).expandingTildeInPath
        if expanded.hasSuffix(".\(VMBundle.pathExtension)") || expanded.contains("/") {
            let url = URL(fileURLWithPath: expanded)
            guard FileManager.default.fileExists(atPath: url.path) else { throw VitrineError.fileNotFound(url.path) }
            return VMBundle(url: url)
        }
        let url = bundleURL(named: nameOrPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VitrineError.fileNotFound("no VM named \(nameOrPath) in \(root.path)")
        }
        return VMBundle(url: url)
    }
}

/// Lock descriptors held by this process, keyed by lock-file path. (flock locks belong to an open
/// file description, so a second open+flock from this process would conflict with its own lock.)
final class BundleLocks: @unchecked Sendable {
    static let shared = BundleLocks()
    private let mutex = NSLock()
    private var fds: [String: Int32] = [:]
    func fd(for key: String) -> Int32? { mutex.lock(); defer { mutex.unlock() }; return fds[key] }
    func set(_ fd: Int32, for key: String) { mutex.lock(); fds[key] = fd; mutex.unlock() }
    func take(_ key: String) -> Int32? { mutex.lock(); defer { mutex.unlock() }; return fds.removeValue(forKey: key) }
}
