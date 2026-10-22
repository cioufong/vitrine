import Foundation
import VitrineCore
import VitrineAgentProtocol

/// Runs one VM as a QEMU child process (plus swtpm for Windows 11) and controls it over QMP.
/// Main-queue confined for its public API; process/QMP I/O happens on background queues.
public final class QEMUMachine: @unchecked Sendable {
    public let bundle: VMBundle
    public let config: VMConfig
    public private(set) var rfb: RFBClient?
    public var onExit: ((QEMUExit) -> Void)?

    private let env: QEMUEnvironment
    private let sockets: QEMUSockets
    private var qemu: Process?
    private var swtpm: Process?
    private var qmp: QMPClient?
    /// Actual backend state established while recovering an unsuccessful suspend. Process
    /// existence alone does not tell callers whether vCPUs resumed.
    public enum SuspendFailureState { case running, paused, unavailable }
    public private(set) var suspendFailureState: SuspendFailureState?
    /// Loopback port forwarded to the Windows agent (nil for other guests).
    public private(set) var agentTCPPort: UInt16?
    /// SMB server for Windows shared folders and drag and drop (nil without Samba or for other guests).
    public private(set) var samba: SambaServer?
    /// Why `samba` is nil for a Windows guest, for the VM log.
    public private(set) var sambaUnavailableReason: String?
    private let io = DispatchQueue(label: "vitrine.qemu.control")
    /// Set before `start` to put the VM on a vmnet or bridged network instead of user networking.
    public var netdev: String?
    private var userNetworking: Bool { config.network.isConnected && netdev == nil }

    public init(bundle: VMBundle, config: VMConfig) throws {
        self.bundle = bundle
        self.config = config
        self.env = try QEMUEnvironment.detect()
        self.sockets = QEMUSockets(directory: bundle.socketDirectory)
    }

    public var isRunning: Bool { qemu?.isRunning ?? false }

    /// SSH endpoint of a running QEMU guest (127.0.0.1:<forwarded port>), readable from any process.
    public static func sshPort(for bundle: VMBundle) -> UInt16? {
        let file = QEMUSockets(directory: bundle.socketDirectory).sshPortFile
        guard bundle.runningPID() != nil, let s = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return UInt16(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Starts QEMU (resuming from a saved state if present) and connects QMP + VNC. On failure every
    /// child started so far (QEMU, swtpm) is terminated before the error is rethrown.
    public func start() async throws {
        do { try await startChildren() } catch {
            await terminateChildren()
            throw error
        }
    }

    private func startChildren() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: bundle.socketDirectory, withIntermediateDirectories: true)
        // Port files too: a stale one (from a run with a different network setup) would point
        // other processes at whatever now listens on that loopback port.
        for s in [sockets.qmp, sockets.qmpTools, sockets.vnc, sockets.agent, sockets.tpm, sockets.sshPortFile, sockets.agentPortFile, sockets.serial] {
            try? fm.removeItem(at: s)
        }
        try prepareEFIVariables()
        let needsTPM = config.guestOS == .windows
        if needsTPM { try startTPM() }

        let resume = fm.fileExists(atPath: bundle.qemuStateURL.path)
        // TCP to the agent rides on user networking: no network, no forward (agents use virtio-serial).
        agentTCPPort = config.guestOS == .windows && userNetworking ? Self.freeLoopbackPort() : nil
        // Without user networking the guest has its own address on the Mac's network instead.
        let sshPort = netdev == nil ? Self.freeLoopbackPort() : nil
        if let sshPort { try? "\(sshPort)".write(to: sockets.sshPortFile, atomically: true, encoding: .utf8) }
        if let agentTCPPort { try? "\(agentTCPPort)".write(to: sockets.agentPortFile, atomically: true, encoding: .utf8) }
        if config.guestOS == .windows, userNetworking {
            do {
                try fm.createDirectory(at: bundle.transferDirectory, withIntermediateDirectories: true)
                samba = try SambaServer(directory: bundle.socketDirectory.appendingPathComponent("smb"),
                                        shares: Self.smbShares(config: config, bundle: bundle))
            } catch {
                sambaUnavailableReason = error.localizedDescription
            }
        }
        var options = QEMUArguments.Options(withTPM: needsTPM, incomingState: resume ? bundle.qemuStateURL : nil,
                                            agentTCPPort: agentTCPPort, sshPort: sshPort, smbCommand: samba?.command)
        options.netdev = netdev
        if agentTCPPort != nil { options.agentToken = try bundle.agentToken() }
        let args = QEMUArguments.build(config: config, bundle: bundle, env: env, sockets: sockets, options: options)
        if !fm.fileExists(atPath: bundle.qemuLogURL.path) { fm.createFile(atPath: bundle.qemuLogURL.path, contents: nil) }
        let log = try FileHandle(forWritingTo: bundle.qemuLogURL)
        log.seekToEndOfFile()
        let logged = args.map { $0.hasPrefix("type=11,value=vitrine.token=") ? "type=11,value=vitrine.token=<redacted>" : $0 }
        log.write(Data("\n=== \(Date()) \(env.system(config.effectiveArchitecture).path) \(logged.joined(separator: " "))\n".utf8))
        let runStart = log.offsetInFile

        let p = Process()
        p.executableURL = env.system(config.effectiveArchitecture)
        p.arguments = args
        // vCPU threads inherit this; at the default QoS macOS parks a lone busy vCPU on an
        // efficiency core (Virtualization.framework's VM process runs its vCPUs user-interactive).
        p.qualityOfService = .userInteractive
        p.standardOutput = log
        p.standardError = log
        let logURL = bundle.qemuLogURL
        p.terminationHandler = { [weak self] proc in
            let output = Self.output(of: logURL, from: runStart)
            let exit = QEMUExit(status: proc.terminationStatus, output: output,
                                uncaughtSignal: proc.terminationReason == .uncaughtSignal)
            DispatchQueue.main.async {
                self?.swtpm?.terminate()
                self?.rfb?.close()
                self?.samba?.remove()
                self?.onExit?(exit)
            }
        }
        try p.run()
        qemu = p

        let qmpPath = sockets.qmp.path, vncPath = sockets.vnc.path
        let (q, r): (QMPClient, RFBClient)
        do {
            (q, r) = try await Task.detached { () -> (QMPClient, RFBClient) in
                let q = try QMPClient(socketPath: qmpPath, timeout: 20)
                let r = try RFBClient(socketPath: vncPath, timeout: 20)
                return (q, r)
            }.value
        } catch {
            // QEMU usually refuses bad options by exiting at once: report its own message, not the
            // resulting "could not connect" to its control socket.
            if !p.isRunning, let log = try? String(contentsOf: logURL, encoding: .utf8),
               let reason = log.split(separator: "\n").last(where: { $0.contains("qemu-system") }) {
                throw VitrineError.backend(String(reason))
            }
            throw error
        }
        qmp = q
        rfb = r
        r.start()
        let offline = WindowsSetup(config).runsOffline
        if offline {
            // Setup needs no network (drivers, OpenSSH and the agent come from the seed disc; the
            // agent talks over virtio-serial), so the virtual cable stays unplugged until setup
            // finishes (see WindowsSetup.runsOffline). When resuming, it is unplugged again after
            // the saved device state is loaded.
            await unplugNetworkForSetup(log)
        }
        if !resume, Self.needsCDBootKeypress(config: config, bundle: bundle) {
            startCDBootKeypresses()
        }
        if resume {
            try await waitForIncomingMigration()
            try? fm.removeItem(at: bundle.qemuStateURL)
            try? await replugAudioIfNeeded()
            // The NIC's restored registers may say "link up": enforce the unplug again.
            if offline { await unplugNetworkForSetup(log) }
        }
    }

    /// The SMB shares for a Windows guest: its shared folders plus the drag-and-drop folder.
    public static func smbShares(config: VMConfig, bundle: VMBundle) -> [SambaServer.Share] {
        var shares = config.shares.filter { unservableReason($0, bundle: bundle) == nil }
            .map { SambaServer.Share(name: $0.name, path: bundle.resolve($0.hostPath).path, readOnly: $0.readOnly,
                                     letter: $0.driveLetter) }
        shares.append(.init(name: SambaServer.transferShare, path: bundle.transferDirectory.path, readOnly: true))
        return shares
    }

    /// Why a shared folder can't be offered over SMB (nil when it can).
    public static func unservableReason(_ share: VMConfig.SharedDirectory, bundle: VMBundle) -> String? {
        if !SambaServer.isValidShareName(share.name) {
            return "\"\(share.name)\" isn't a valid Windows share name"
        }
        if !SambaServer.isServablePath(bundle.resolve(share.hostPath).path) {
            return "Samba can't carry this path (\"%\", or a leading/trailing space or trailing backslash)"
        }
        return nil
    }

    // MARK: USB

    /// Plugs a disk image (as a USB flash drive) or a Mac USB device into the guest's xHCI
    /// controller under QMP id `id`. Returns a warning when QEMU reported trouble claiming a host
    /// device (macOS keeps devices its own drivers use unless QEMU runs as root).
    @discardableResult
    public func attachUSB(_ attachment: USBAttachment, id: String) async throws -> String? {
        switch attachment {
        case .image(let path, let readOnly):
            guard FileManager.default.isReadableFile(atPath: path) else { throw VitrineError.io("can't read \(path)") }
            let node = "\(id)-img"
            // UDIF disk images (.dmg) carry a container format; QEMU's dmg driver reads them (read-only).
            let udif = DiskImage.isUDIF(URL(fileURLWithPath: path))
            let ro = readOnly || udif
            try await control {
                try $0.execute("blockdev-add", arguments: [
                    "driver": udif ? "dmg" : "raw", "node-name": node, "read-only": ro,
                    "file": ["driver": "file", "filename": path, "read-only": ro] as [String: Any]])
            }
            do {
                try await control {
                    try $0.execute("device_add", arguments: ["driver": "usb-storage", "bus": "xhci.0", "id": id,
                                                             "drive": node, "removable": true])
                }
            } catch {
                _ = try? await control { try $0.execute("blockdev-del", arguments: ["node-name": node]) }
                throw error
            }
            return nil
        case .host(let device):
            let logStart = (try? FileManager.default.attributesOfItem(atPath: bundle.qemuLogURL.path)[.size] as? UInt64) ?? 0
            try await control {
                try $0.execute("device_add", arguments: ["driver": "usb-host", "bus": "xhci.0", "id": id,
                                                         "hostbus": device.busNumber, "hostaddr": Int(device.address)])
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let lines = (Self.output(of: bundle.qemuLogURL, from: logStart) ?? "")
                .split(separator: "\n").filter { $0.contains("libusb") || $0.contains("usb-host") }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }
    }

    /// Unplugs a device added with `attachUSB` and waits for the guest to let go of it.
    public func detachUSB(_ attachment: USBAttachment, id: String) async throws {
        // Idempotent: a retry after a timed-out detach finds the device already gone.
        do {
            try await control { try $0.execute("device_del", arguments: ["id": id]) }
        } catch where "\(error)".contains("not found") {} // "Device 'usb1' not found"
        var gone = false
        for _ in 0..<100 {
            let list = try await control { try $0.execute("qom-list", arguments: ["path": "/machine/peripheral"]) as? [[String: Any]] } ?? []
            if !list.contains(where: { $0["name"] as? String == id }) { gone = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard gone else {
            throw VitrineError.backend("the guest didn't release \(attachment.label); eject it in the guest and try again")
        }
        if case .image = attachment {
            do {
                try await control { _ = try $0.execute("blockdev-del", arguments: ["node-name": "\(id)-img"]) }
            } catch where "\(error)".contains("Failed to find node") {} // removed by an earlier attempt
        }
    }

    /// Applies changed shared folders to the running SMB server.
    public func updateShares(_ config: VMConfig) throws {
        try samba?.update(shares: Self.smbShares(config: config, bundle: bundle))
    }

    /// What QEMU wrote to the log during one run.
    private static func output(of logURL: URL, from offset: UInt64) -> String? {
        guard let h = try? FileHandle(forReadingFrom: logURL) else { return nil }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: offset)) != nil, let data = try? h.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Unplugs the virtual network cable (see start()).
    private func unplugNetworkForSetup(_ log: FileHandle) async {
        do { try await control { _ = try $0.execute("set_link", arguments: ["name": "net0", "up": false]) } }
        catch { log.write(Data("Vitrine: could not unplug the network during setup: \(error)\n".utf8)) }
    }

    /// Windows install media boot through cdboot.efi, which waits a few seconds for "Press any key to
    /// boot from CD or DVD" and otherwise skips the disc. Only on the very first boot (system disk
    /// still blank) is the installer what the user wants, so only then is a key pressed for them;
    /// after Setup's first reboot the prompt times out and the firmware boots the installed disk.
    static func needsCDBootKeypress(config: VMConfig, bundle: VMBundle) -> Bool {
        guard config.guestOS == .windows, config.installMedia != nil, let disk = config.disks.first else { return false }
        return DiskImage.isBlank(bundle.resolve(disk.path))
    }

    private func startCDBootKeypresses() {
        Task { [weak self] in
            // The prompt appears a second or two after the firmware hands over; keep tapping through
            // that window. The key is Down: cdboot takes any key, while Setup's first screen, which
            // follows seconds later with its Cancel button focused, ignores it (Return would cancel
            // setup if a tap arrived late, as they do when the Mac is busy).
            for _ in 0..<60 {
                guard let self, self.isRunning else { return }
                _ = try? await self.control {
                    try $0.execute("send-key", arguments: ["keys": [["type": "qcode", "data": "down"]]])
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func startTPM() throws {
        guard let swtpmURL = env.swtpm else {
            throw VitrineError.unsupported("Windows 11 needs a TPM: install it with `brew install swtpm`")
        }
        try FileManager.default.createDirectory(at: bundle.tpmStateDirectory, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = swtpmURL
        p.arguments = ["socket", "--tpm2", "--tpmstate", "dir=\(bundle.tpmStateDirectory.path)",
                       "--ctrl", "type=unixio,path=\(sockets.tpm.path)", "--terminate",
                       "--flags", "startup-clear"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        swtpm = p
        // QEMU connects to the TPM socket at startup; wait until swtpm created it.
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: sockets.tpm.path) && Date() < deadline { usleep(50_000) }
    }

    private func waitForIncomingMigration() async throws {
        for _ in 0..<600 {
            let status = try await control { try $0.status() }
            if status == "running" { return }
            if status == "paused" || status == "postmigrate" { try await control { try $0.execute("cont") }; return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw VitrineError.backend("timed out restoring the saved state")
    }

    /// Runs a QMP command off the main thread.
    @discardableResult
    func control<T>(_ body: @escaping (QMPClient) throws -> T) async throws -> T {
        guard let qmp else { throw VitrineError.backend("QEMU control channel not connected") }
        return try await withCheckedThrowingContinuation { cont in
            io.async { cont.resume(with: Result { try body(qmp) }) }
        }
    }

    // MARK: Lifecycle

    public func requestShutdown() async { _ = try? await control { try $0.execute("system_powerdown") } }
    public func pause() async throws { try await control { try $0.execute("stop") } }
    public func resume() async throws { try await control { try $0.execute("cont") } }
    /// Link state of the VM's network adapter (a pulled cable when false).
    public func setLink(up: Bool) async throws {
        try await control { try $0.execute("set_link", arguments: ["name": "net0", "up": up]) }
    }

    /// Terminates QEMU without going through QMP (which may be wedged) and waits for it, and
    /// swtpm, to exit — escalating to SIGKILL after a few seconds.
    public func forceStop() async { await terminateChildren() }

    private func terminateChildren() async {
        rfb?.close()
        for p in [qemu, swtpm].compactMap({ $0 }) where p.isRunning { p.terminate() }
        await waitForExit(of: [qemu, swtpm].compactMap { $0 }, timeout: 5)
        for p in [qemu, swtpm].compactMap({ $0 }) where p.isRunning { kill(p.processIdentifier, SIGKILL) }
        await waitForExit(of: [qemu, swtpm].compactMap { $0 }, timeout: 2)
    }

    private func waitForExit(of processes: [Process], timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while processes.contains(where: \.isRunning), Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private var hotplugAudio: Bool { config.features.sound && QEMUArguments.audioModel(config) == .usbAudio }

    private func replugAudioIfNeeded() async throws {
        guard hotplugAudio else { return }
        try await control { try $0.execute("device_add", arguments: ["driver": "usb-audio", "id": "audio0",
                                                                      "bus": "xhci.0", "audiodev": "snd0"]) }
    }

    /// The UEFI variable store, created from QEMU's template on first start. With Secure Boot on
    /// (x86_64), Microsoft's keys are enrolled; switching it on or off recreates the store, so the
    /// firmware's boot entries start over (Windows boots through its fallback loader and re-adds them).
    /// Not while resuming: the saved machine state carries the store it ran with.
    func prepareEFIVariables() throws {
        let fm = FileManager.default
        let marker = bundle.url.appendingPathComponent("efivars.secureboot")
        let want = config.features.secureBoot && config.effectiveArchitecture == .x86_64
        let have = fm.fileExists(atPath: marker.path)
        let exists = fm.fileExists(atPath: bundle.efiVarsURL.path)
        guard !exists || (want != have && !fm.fileExists(atPath: bundle.qemuStateURL.path)) else { return }
        let fresh = bundle.url.appendingPathComponent("efivars.fd.new")
        try? fm.removeItem(at: fresh)
        try fm.copyItem(at: env.firmwareVarsTemplate(config.effectiveArchitecture), to: fresh)
        if want {
            try SecureBootVars.enroll(fresh, platformKey: SecureBootVars.makePlatformKey(commonName: "Vitrine \(config.name) platform key"))
        }
        guard rename(fresh.path, bundle.efiVarsURL.path) == 0 else { throw VitrineError.io("could not replace the UEFI variable store") }
        if want { fm.createFile(atPath: marker.path, contents: Data()) } else { try? fm.removeItem(at: marker) }
    }

    /// Presses `qcodes` together in the guest and releases them (QMP send-key).
    public func sendKeys(qcodes: [String]) async throws {
        _ = try await control { try $0.execute("send-key", arguments: ["keys": qcodes.map { ["type": "qcode", "data": $0] }]) }
    }

    /// Saves RAM + device state to the bundle (QEMU migration to a file), then quits.
    public func suspend() async throws {
        suspendFailureState = nil
        let wasPaused = try await control { try $0.status() } == "paused"
        let partial = bundle.url.appendingPathComponent("state.qemusave.partial")
        do {
            try await saveAndQuit(partial: partial)
        } catch {
            await recoverFailedSuspend(wasPaused: wasPaused, partial: partial)
            if suspendFailureState == .unavailable {
                throw VitrineError.backend("\(error.localizedDescription). Could not confirm QEMU recovery; the VM remains owned for recovery or force stop")
            }
            throw error
        }
    }

    /// QEMU reports mounted 9p exports and other devices that cannot be migrated here.
    public func migrationBlocker() async -> String? {
        let blocked = (try? await control { try $0.execute("query-migrate") as? [String: Any] })?["blocked-reasons"] as? [String]
        guard let blocked, !blocked.isEmpty else { return nil }
        return blocked.joined(separator: "; ")
    }

    private func saveAndQuit(partial: URL) async throws {
        if hotplugAudio {
            _ = try? await control { try $0.execute("device_del", arguments: ["id": "audio0"]) }
            for _ in 0..<50 { // wait for the unplug to complete
                let list = (try? await control { try $0.execute("qom-list", arguments: ["path": "/machine/peripheral"]) as? [[String: Any]] }) ?? []
                if !list.contains(where: { $0["name"] as? String == "audio0" }) { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        if let blocker = await migrationBlocker() {
            throw VitrineError.backend("this VM can't be suspended: \(blocker)")
        }
        try await control { try $0.execute("stop") }
        // Save to a temporary name; only a completed save becomes state.qemusave.
        try? FileManager.default.removeItem(at: partial)
        try await control { try $0.execute("migrate", arguments: ["uri": "file:\(partial.path)"]) }
        for _ in 0..<6000 {
            guard isRunning else {
                throw VitrineError.backend("QEMU exited while saving the machine state")
            }
            let info = try await control { try $0.execute("query-migrate") as? [String: Any] }
            switch info?["status"] as? String {
            case "completed":
                // Atomic replacement preserves a previous valid save if publication fails.
                guard rename(partial.path, bundle.qemuStateURL.path) == 0 else {
                    throw VitrineError.io("could not publish saved state: \(String(cString: strerror(errno)))")
                }
                _ = try? await control { try $0.execute("quit") }
                await waitForExit(of: [qemu, swtpm].compactMap { $0 }, timeout: 10)
                await terminateChildren() // no-op unless something is still hanging around
                return
            case "failed", "cancelled":
                throw VitrineError.backend("QEMU could not save the machine state: \(info?["error-desc"] as? String ?? "unknown")")
            default:
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        throw VitrineError.backend("timed out saving the machine state")
    }

    /// A QMP I/O error invalidates that reply stream. Reconnect before cancellation/recovery, and
    /// never unlink an output file while QEMU may still be writing migration data into it.
    private func recoverFailedSuspend(wasPaused: Bool, partial: URL) async {
        suspendFailureState = .unavailable
        guard isRunning else { return }
        var migrationSettled = false
        do {
            qmp = nil
            let path = sockets.qmp.path
            qmp = try await Task.detached { try QMPClient(socketPath: path, timeout: 2, commandTimeout: 3) }.value
            var info = try await control { try $0.execute("query-migrate") as? [String: Any] }
            let terminal = ["none", "completed", "failed", "cancelled"]
            if !terminal.contains(info?["status"] as? String ?? "") {
                try await control { try $0.execute("migrate_cancel") }
                for _ in 0..<50 {
                    info = try await control { try $0.execute("query-migrate") as? [String: Any] }
                    if terminal.contains(info?["status"] as? String ?? "") { break }
                    // Recovery must also finish when its caller's task was cancelled.
                    await Task.detached { try? await Task.sleep(nanoseconds: 100_000_000) }.value
                }
            }
            guard terminal.contains(info?["status"] as? String ?? "") else {
                throw VitrineError.backend("migration did not cancel")
            }
            migrationSettled = true
            try await control { try $0.execute(wasPaused ? "stop" : "cont") }
            if hotplugAudio {
                let devices = try await control { try $0.execute("qom-list", arguments: ["path": "/machine/peripheral"]) as? [[String: Any]] } ?? []
                if !devices.contains(where: { $0["name"] as? String == "audio0" }) { try await replugAudioIfNeeded() }
            }
            // Removing an unpublished save is safe only after migration has actually settled.
            try? FileManager.default.removeItem(at: partial)
        } catch {
            // Keep the partial and live backend when recovery is uncertain. The controller retains
            // the run lock instead of announcing a running VM or silently terminating the session.
        }
        if migrationSettled, let status = try? await control({ try $0.status() }) {
            switch status {
            case "running": suspendFailureState = .running
            case "paused": suspendFailureState = .paused
            default: break
            }
        }
    }

    /// Asks the kernel for a free loopback TCP port.
    static func freeLoopbackPort() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        return ok ? UInt16(bigEndian: addr.sin_port) : nil
    }

    /// Changes the guest resolution of a QEMU VM run by any process, through a second (shared) VNC
    /// connection. Returns the size the display reports afterwards.
    public static func setDisplaySize(bundle: VMBundle, width: Int, height: Int) async throws -> (Int, Int) {
        let path = QEMUSockets(directory: bundle.socketDirectory).vnc.path
        let rfb = try RFBClient(socketPath: path, timeout: 3)
        defer { rfb.close() }
        rfb.start()
        for _ in 0..<40 where !rfb.supportsResize { try await Task.sleep(nanoseconds: 50_000_000) }
        guard rfb.supportsResize else { throw VitrineError.unsupported("this VM's display can't be resized") }
        rfb.requestDesktopSize(width: width, height: height)
        for _ in 0..<100 {
            if rfb.width == width && rfb.height == height { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return (rfb.width, rfb.height)
    }

    /// Connects to the agent of a QEMU guest run by any process: over virtio-serial, or (`tcp`) the
    /// forwarded TCP port older Windows agents listen on. Nil when that transport isn't available.
    public static func connectAgent(bundle: VMBundle, tcp: Bool = false) -> AgentChannel? {
        let sockets = QEMUSockets(directory: bundle.socketDirectory)
        if tcp {
            guard bundle.runningPID() != nil, let s = try? String(contentsOf: sockets.agentPortFile, encoding: .utf8),
                  let port = UInt16(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            return connectLoopback(port: port)
        }
        guard let fd = try? UnixSocket.connect(path: sockets.agent.path, timeout: 0.5) else { return nil }
        return AgentChannel(fileDescriptor: fd)
    }

    static func connectLoopback(port: UInt16) -> AgentChannel? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = port.bigEndian
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc != 0 { close(fd); return nil }
        return AgentChannel(fileDescriptor: fd)
    }

    /// Connects to the guest agent: loopback TCP (Windows) or the virtio-serial channel.
    /// Whether the next agent connection uses virtio-serial. Windows agents use it when the guest has
    /// the vioser driver (only QEMU drives the host end, so guest programs can't pose as the host);
    /// older ones only listen on TCP. The host alternates until one completes a handshake.
    public private(set) var agentOverSerial = true

    /// A connection ended without a handshake: try the other transport next (Windows guests).
    public func agentTransportFailed() {
        if agentTCPPort != nil { agentOverSerial.toggle() }
    }

    public func connectAgent() -> AgentChannel? {
        if let port = agentTCPPort, !agentOverSerial { return Self.connectLoopback(port: port) }
        guard let fd = try? UnixSocket.connect(path: sockets.agent.path, timeout: 0.5) else { return nil }
        return AgentChannel(fileDescriptor: fd)
    }
}
