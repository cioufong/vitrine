import Foundation
import CryptoKit
import VitrineCore

/// Creates Windows 11 VM bundles on the QEMU backend: Arm64 (HVF, near-native; x64 apps run through
/// Windows' own Prism emulation) or x64 (full TCG emulation — compatibility option, slow).
public enum WindowsCreator {
    public struct Options {
        public var name: String
        public var architecture: VMConfig.Architecture = .aarch64
        public var installISO: URL
        /// An emulated x64 guest is bound by TCG throughput, not by per-core latency: 7-Zip under
        /// `-accel tcg,thread=multi` went from 4 426 to 8 330 MIPS (4→8 vCPUs) on an M1 Max, so the
        /// default gives emulated guests every performance core but two. Arm64 guests run natively
        /// and idle cheaply, so they keep the conservative half-the-cores default.
        public var cpuCount = Options.defaultCPUCount(for: .aarch64)
        public var memoryMiB: UInt64 = 8192
        public var diskBytes: UInt64 = 80 << 30
        /// Account for unattended setup; nil = interactive Windows Setup.
        public var account: (fullName: String, username: String, password: String)?

        /// Default vCPU count for a Windows guest of `architecture` on this Mac.
        public static func defaultCPUCount(for architecture: VMConfig.Architecture,
                                           processors: Int = ProcessInfo.processInfo.processorCount) -> Int {
            switch architecture {
            case .aarch64:
                return max(4, processors / 2)
            case .x86_64:
                // Leave two cores for the host: an emulating vCPU thread never yields, so the guest
                // must not be allowed to claim every core.
                return max(4, min(8, processors - 2))
            }
        }
        /// Mounted/unpacked virtio-win ISO (drivers are copied for the guest architecture).
        public var virtioWinISO: URL?
        /// Windows agent executable to preinstall.
        public var agentExecutable: URL?
        /// OpenSSH MSI to install from the seed disc (see fetchOpenSSH); nil = Windows Update.
        public var openSSHInstaller: URL?
        public init(name: String, installISO: URL) { self.name = name; self.installISO = installISO }
    }

    /// Drivers Windows needs on Vitrine's QEMU machine (network, serial, balloon, RNG, input, GPU).
    static let driverFolders = ["NetKVM", "vioserial", "Balloon", "viorng", "vioinput", "viogpudo", "vioscsi"]

    /// Copies the Windows 11 drivers for `arch` out of a virtio-win ISO into `dest`.
    static func extractDrivers(iso: URL, arch: VMConfig.Architecture, to dest: URL) throws {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("virtio-win-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mount) }
        func run(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw VitrineError.io("hdiutil \(args.first ?? "") failed") }
        }
        try run(["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, iso.path])
        defer { try? run(["detach", mount.path, "-force"]) }
        let archDir = arch == .aarch64 ? "ARM64" : "amd64"
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        for folder in driverFolders {
            let src = mount.appendingPathComponent(folder).appendingPathComponent("w11").appendingPathComponent(archDir)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            try FileManager.default.copyItem(at: src, to: dest.appendingPathComponent(folder))
            FileManager.default.makeWritable(dest.appendingPathComponent(folder)) // copied off read-only media
        }
    }

    /// Pinned virtio-win release. Upstream publishes no checksum for the ISO, so the SHA-256 was
    /// taken from the archived file itself; bump both together.
    static let virtioWinVersion = "0.1.302"
    static let virtioWinSHA256 = "303f7ae40dad495d6ae474fdc571df58958a4dbc5c37a522d80f9a203867949d"
    public static let virtioWinURL = URL(string: "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-\(virtioWinVersion)-1/virtio-win-\(virtioWinVersion).iso")!

    /// Microsoft's official download pages (the ISO links themselves are session-bound).
    public static let downloadPageArm = URL(string: "https://www.microsoft.com/software-download/windows11arm64")!
    public static let downloadPageX64 = URL(string: "https://www.microsoft.com/software-download/windows11")!

    /// Downloads (cached, checksum-verified) the virtio-win driver ISO. Its drivers are installed
    /// into the guest with administrator rights, so an unverified file is never used.
    public static func fetchVirtioWin(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let cache = VMLibrary.cacheDirectory.appendingPathComponent("windows/virtio-win.iso")
        if FileManager.default.fileExists(atPath: cache.path), (try? sha256(of: cache)) == virtioWinSHA256 { return cache }
        try? FileManager.default.removeItem(at: cache)
        let file = try await QEMUDownload.download(virtioWinURL, to: cache, progress: progress)
        guard try sha256(of: file) == virtioWinSHA256 else {
            try? FileManager.default.removeItem(at: file)
            throw VitrineError.io("virtio-win \(virtioWinVersion) failed its checksum; not using it")
        }
        return file
    }

    /// Microsoft's Win32-OpenSSH MSI (pinned release and SHA-256, as published on GitHub). Setup
    /// installs it from the seed disc: Windows' own OpenSSH is a Feature on Demand that comes from
    /// Windows Update, which takes minutes natively and hours in an emulated x64 guest.
    static let openSSHRelease = "10.0.0.0p2-Preview"
    static func openSSHMSI(_ arch: VMConfig.Architecture) -> (name: String, sha256: String) {
        arch == .aarch64
            ? ("OpenSSH-ARM64-v10.0.0.0.msi", "7a17d0e22d004fb47ca4bfd8fef926fa305de4ebf70a6f3c7a29c39aabef0023")
            : ("OpenSSH-Win64-v10.0.0.0.msi", "ddec9c53864280759cf9f74791cefd387100e3946aa849a1c138a4ed1b96b7d9")
    }

    /// Downloads (cached, checksum-verified) the OpenSSH MSI for `arch`.
    public static func fetchOpenSSH(arch: VMConfig.Architecture, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let msi = openSSHMSI(arch)
        let cache = VMLibrary.cacheDirectory.appendingPathComponent("windows/\(msi.name)")
        if FileManager.default.fileExists(atPath: cache.path), (try? sha256(of: cache)) == msi.sha256 { return cache }
        try? FileManager.default.removeItem(at: cache)
        let url = URL(string: "https://github.com/PowerShell/Win32-OpenSSH/releases/download/\(openSSHRelease)/\(msi.name)")!
        let file = try await QEMUDownload.download(url, to: cache, progress: progress)
        guard try sha256(of: file) == msi.sha256 else {
            try? FileManager.default.removeItem(at: file)
            throw VitrineError.io("\(msi.name) failed its checksum; not using it")
        }
        return file
    }

    public enum PreparePhase: Sendable {
        case fetchingVirtioWin, virtioWin(Double)
        case fetchingOpenSSH, openSSH(Double)
        /// The OpenSSH download failed (the message says why): Setup gets SSH from Windows Update.
        case openSSHUnavailable(String)
    }

    /// Fetches what an unattended setup puts on the seed disc (virtio-win drivers, and OpenSSH when
    /// it can be had) into `o`. Interactive setups (no account) need neither.
    public static func prepare(options o: Options, progress: @escaping @Sendable (PreparePhase) -> Void) async throws -> Options {
        guard o.account != nil else { return o }
        var o = o
        progress(.fetchingVirtioWin)
        o.virtioWinISO = try await fetchVirtioWin { progress(.virtioWin($0)) }
        progress(.fetchingOpenSSH)
        // Optional: without it Setup gets SSH from Windows Update (slow, hours when emulated).
        do {
            o.openSSHInstaller = try await fetchOpenSSH(arch: o.architecture) { progress(.openSSH($0)) }
        } catch {
            try Task.checkCancellation() // a Cancel isn't a failed download
            progress(.openSSHUnavailable(error.localizedDescription))
        }
        try Task.checkCancellation() // cached downloads return without checking
        return o
    }

    static func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    public static func create(_ o: Options) throws -> VMBundle {
        // `cpuCount` defaults to the aarch64 figure because a stored property cannot depend on
        // `architecture`; when the caller left it alone, pick the count that suits the architecture.
        let cpuCount = o.cpuCount == Options.defaultCPUCount(for: .aarch64)
            ? Options.defaultCPUCount(for: o.architecture) : o.cpuCount
        var config = VMConfig(name: o.name, guestOS: .windows, cpuCount: cpuCount, memoryMiB: o.memoryMiB)
        config.backend = .qemu
        config.architecture = o.architecture
        config.installMedia = o.installISO.path
        config.disks = [.init(path: "disk.img", interface: .nvme)] // QEMU needs raw images (no ASIF)
        config.display = VMConfig.DisplayConfig(widthPixels: 1920, heightPixels: 1080, pixelsPerInch: 96)
        config.installedOS = o.architecture == .aarch64 ? "Windows 11 on Arm" : "Windows 11 (x64, emulated)"
        return try VMBundle.create(at: VMLibrary.bundleURL(named: o.name), config: config) { bundle, config in
            try DiskImage.create(at: bundle.resolve("disk.img"), sizeBytes: o.diskBytes, format: .raw)
            if let acct = o.account {
                var drivers: URL?
                if let vw = o.virtioWinISO {
                    let d = bundle.cacheDirectory.appendingPathComponent("drivers")
                    try extractDrivers(iso: vw, arch: o.architecture, to: d)
                    drivers = d
                }
                var unattend = WindowsUnattend.Options(architecture: o.architecture,
                                                       computerName: WindowsUnattend.computerName(forVMName: o.name),
                                                       fullName: acct.fullName, username: acct.username, password: acct.password)
                unattend.skipOOBE = o.architecture == .x86_64 // emulated: OOBE's watchdog trips (see Options)
                try WindowsUnattend.makeSeedISO(at: bundle.resolve("seed.iso"), options: unattend,
                                                driversDirectory: drivers, agentExecutable: o.agentExecutable,
                                                openSSHInstaller: o.openSSHInstaller)
                if let drivers { try? FileManager.default.removeItemForcibly(at: drivers) }
                config.extraMedia = ["seed.iso"]
                config.windowsSetupOffline = o.openSSHInstaller != nil ? true : nil
                config.account = .init(fullName: acct.fullName, username: acct.username)
                config.account?.setupFinalized = true
                try GuestCredentialStore.setPassword(acct.password, in: bundle)
            }
            try config.validate(bundle: bundle)
        }
    }
}
