import Foundation
import CoreGraphics
import Virtualization
import Combine
import VitrineCore
import VitrineAgentHost
import VitrineAgentProtocol
import VitrineQEMU

/// Owns one running VM — a VZVirtualMachine or a QEMU child process. Main-actor confined.
@MainActor
public final class VirtualMachineController: NSObject, ObservableObject {
    public enum RunState: String, Equatable {
        case stopped, starting, running, paused, suspending, suspended, stopping, error
    }

    public let bundle: VMBundle
    @Published public private(set) var config: VMConfig
    @Published public private(set) var state: RunState = .stopped {
        didSet {
            // A running VM keeps the Mac from idle-sleeping (see VitrinePreferences.keepAwakeWhileRunning).
            SleepGuard.shared.set(bundle.url.path, running: [.starting, .running, .suspending, .stopping].contains(state))
            switch state {
            case .running: if runningSince == nil { runningSince = Date() }
            case .paused: break
            default: runningSince = nil
            }
        }
    }
    @Published public private(set) var lastError: String?
    @Published public private(set) var agent: AgentSession?
    /// Connection to the guest agent. The app shows its own translated text for each case.
    public enum AgentConnection: Equatable, Sendable {
        case notConnected, connecting
        case connected(os: String, agentVersion: String)
        case disconnected(reason: String?)
    }
    @Published public private(set) var agentConnection: AgentConnection = .notConnected
    /// The guest's CPU, memory and disk use as its agent last reported them; nil without an agent.
    @Published public private(set) var guestStats: GuestStats?
    /// When the VM last started or resumed (for the status bar's uptime when there is no agent).
    @Published public private(set) var runningSince: Date?
    /// The status bar's network switch: the cable is unplugged until it is plugged back in or the
    /// VM stops. Not saved; the next start is connected again.
    @Published public private(set) var networkCableDisconnected = false
    /// `agentConnection` in English, for the CLI and logs.
    public var agentStatus: String {
        switch agentConnection {
        case .notConnected: "not connected"
        case .connecting: "connecting"
        case .connected(let os, let version): "connected (\(os), agent \(version))"
        case .disconnected(let reason): "disconnected" + (reason.map { ": \($0)" } ?? "")
        }
    }

    public var virtualMachine: VZVirtualMachine? { vz?.vm }
    /// The running Virtualization.framework machine.
    private(set) var vz: VZBackend?
    /// Set instead of `vz` for VMs on the QEMU backend.
    @Published public private(set) var qemu: QEMUMachine?
    /// Whichever of the two is running.
    var backend: MachineBackend? { qemu ?? vz }
    private var agentRetryTask: Task<Void, Never>?
    let log: VMLog
    /// USB drives and devices plugged into the running VM.
    @Published public internal(set) var usbAttachments: [AttachedUSB] = []
    var nextUSBNumber = 1
    /// Bumped whenever a run ends, so async work started in an earlier run can tell it's stale.
    var runGeneration = 0
    var controlServer: VMControlServer?
    /// TCP port forwards into a Virtualization.framework guest (QEMU forwards with hostfwd itself).
    var portForwarder: PortForwarder?
    /// The vmnet network or bridge the adapter is plugged into (nil: NAT).
    var networkLink: NetworkLink?
    /// The view presenting this VZ guest in its owner's UI (a VM window or a seamless-mode sink), used
    /// for screenshots and input requested over the control socket. Without one, an invisible
    /// `automationSink` presents the display on demand.
    public var displayViewProvider: (() -> GuestDisplayView?)?
    /// Carries out `stop`, `suspend` and `forceStop` requests from the control socket, for owners
    /// that do more around them (the app leaves Coherence and keeps a thumbnail). Nil: the
    /// controller just calls the method.
    public var lifecycleRequestHandler: ((VMControl.Request.Op) -> Void)?
    var automationSink: DisplaySink?
    let automationInput = AutomationInputQueue()

    public init(bundle: VMBundle) throws {
        self.bundle = bundle
        self.config = try bundle.loadConfig()
        self.log = VMLog(url: bundle.logURL)
        super.init()
        if hasSavedState { state = .suspended }
    }

    public var hasSavedState: Bool { bundle.hasSavedState }

    private var usesQEMU: Bool { config.effectiveBackend == .qemu }
    private var isLive: Bool { backend != nil }

    // MARK: Lifecycle

    public func start(recovery: Bool = false) async throws {
        guard state == .stopped || state == .suspended || state == .error else { return }
        lastError = nil
        config = try bundle.loadConfig()
        try bundle.acquireRunLock()
        do {
            try beginDisposableRunIfNeeded()
        } catch {
            bundle.releaseRunLock()
            throw error
        }
        state = .starting
        if usesQEMU {
            do {
                try config.validate(bundle: bundle)
                let machine = try QEMUMachine(bundle: bundle, config: config)
                machine.onExit = { [weak self, weak machine] exit in
                    guard let self, let machine, self.qemu === machine else { return }
                    if self.state == .suspending { return }
                    if WindowsSetup(self.config).isFinished(by: exit, isRunning: self.state == .running) {
                        self.finishWindowsSetup()
                        return
                    }
                    if exit.killedByHost, self.state != .stopping {
                        self.log.write("QEMU was terminated from the host (status \(exit.status))")
                    }
                    let err: Error? = (exit.status == 0 || self.state == .stopping) ? nil
                        : VitrineError.backend("QEMU exited with status \(exit.status)\n\(exit.tail ?? "")")
                    self.didStop(error: err)
                }
                qemu = machine
                networkLink = try NetworkLink.open(bundle: bundle, config: config, qemu: true)
                machine.netdev = networkLink?.qemuNetdev
                if let link = networkLink { log.write("network: \(link.summary)") }
                try await machine.start()
                state = .running
                log.write("started on QEMU (\(config.effectiveArchitecture.rawValue), cpus=\(config.cpuCount) mem=\(config.memoryMiB)MiB)")
                startAgentConnector()
                didStartCommon()
            } catch {
                await qemu?.forceStop()
                qemu = nil
                fail(error)
                throw error
            }
            return
        }
        do {
            let restoring = hasSavedState && !recovery
            let withUSB = !restoring || FileManager.default.fileExists(atPath: bundle.savedStateUSBMarkerURL.path)
            networkLink = try NetworkLink.open(bundle: bundle, config: config, qemu: false)
            if let link = networkLink { log.write("network: \(link.summary)") }
            let vzConfig = try ConfigurationBuilder.build(bundle: bundle, config: config, usbController: withUSB,
                                                          networkAttachment: networkLink?.vzAttachment)
            // What the configuration really has (no xHCI before macOS 15), not what was asked for.
            let hasUSBController: Bool
            if #available(macOS 15, *) { hasUSBController = !vzConfig.usbControllers.isEmpty } else { hasUSBController = false }
            let vm = VZVirtualMachine(configuration: vzConfig)
            vm.delegate = self
            vz = VZBackend(vm: vm, bundle: bundle, hasUSBController: hasUSBController)
            if hasSavedState && !recovery {
                try await restoreSavedState(vm, vzConfig: vzConfig)
            } else {
                if hasSavedState {
                    // A recovery boot can modify the disk; the old RAM image would no longer match it.
                    try? FileManager.default.removeItem(at: bundle.savedStateURL)
                    try? FileManager.default.removeItem(at: bundle.savedStateUSBMarkerURL)
                    try? FileManager.default.removeItem(at: bundle.suspendedUSBURL)
                    log.write("discarded saved state for a recovery boot")
                }
                try await boot(vm, recovery: recovery)
                watchProvisioning()
            }
            state = .running
            log.write("started (cpus=\(config.cpuCount) mem=\(config.memoryMiB)MiB)")
            startAgentConnector()
            autoInstallAgentIfNeeded()
            didStartCommon()
        } catch {
            fail(error)
            throw error
        }
    }

    /// Where Windows setup is. `.restarting` while the VM restarts by itself after setup (observers
    /// shouldn't treat the brief stop as the end of the session).
    public var windowsSetup: WindowsSetup { restartingAfterSetup ? .restarting : WindowsSetup(config) }
    @Published private var restartingAfterSetup = false

    /// The agent only exists once Windows setup's first-logon script has installed it: remember
    /// that, so a setup whose own power-off was interrupted still gets its media ejected.
    func noteWindowsSetupProgress() {
        var c = (try? bundle.loadConfig()) ?? config
        guard case .installing = WindowsSetup(c) else { return }
        c.windowsSetupAgentSeen = true
        try? saveConfig(c)
    }

    /// At a stop after setup got as far as the agent: eject the media setup's power-off would have.
    private func ejectMediaIfSetupDone() {
        guard WindowsSetup(config) == .agentSeen else { return }
        let ejected = config.ejectInstallMedia(in: bundle)
        try? bundle.saveConfig(config)
        if !ejected.isEmpty { log.write("Windows setup had finished; ejected \(ejected.joined(separator: ", "))") }
    }

    private func finishWindowsSetup() {
        restartingAfterSetup = true
        let ejected = config.ejectInstallMedia(in: bundle)
        try? bundle.saveConfig(config)
        didStop(error: nil)
        log.write("Windows setup finished; ejected \(ejected.joined(separator: ", ")) and restarting")
        Task { [weak self] in
            guard let self else { return }
            defer { self.restartingAfterSetup = false }
            do { try await self.start() } catch { self.log.write("restart after setup failed: \(error.localizedDescription)") }
        }
    }

    private func boot(_ vm: VZVirtualMachine, recovery: Bool) async throws {
        if config.guestOS == .macOS {
            try await vm.start(options: try startOptions(recovery: recovery))
        } else {
            try await vm.start()
        }
    }

    private func startOptions(recovery: Bool) throws -> VZMacOSVirtualMachineStartOptions {
        let options = VZMacOSVirtualMachineStartOptions()
        options.startUpFromMacOSRecovery = recovery
        #if canImport(DiskImageKit) // macOS 27 SDK (provisioning API ships alongside DiskImageKit)
        if #available(macOS 27, *), let account = config.account, !account.provisioned, !recovery {
            guard let password = GuestCredentialStore.password(in: bundle) else {
                throw VitrineError.invalidConfig("no stored password for guest account \(account.username)")
            }
            let p = VZMacGuestProvisioningOptions()
            p.fullName = account.fullName
            p.username = account.username
            p.password = password
            p.logsInAutomatically = account.autoLogin
            p.enablesRemoteLogin = account.remoteLogin
            try options.setGuestProvisioning(p)
            log.write("first boot: provisioning account \(account.username)")
        }
        #endif
        return options
    }

    /// Provisioning only takes effect if the first boot gets far enough, so it is marked done only
    /// once there's evidence: SSH answering (remote login), the agent connecting, or — for accounts
    /// without remote login — three minutes of uptime. Until then every start re-sends it.
    private func watchProvisioning() {
        guard let account = config.account, !account.provisioned else { return }
        let startedAt = Date()
        Task { [weak self] in
            while let self, self.state == .running || self.state == .starting {
                let evidence: Bool
                if self.agent != nil {
                    evidence = true
                } else if account.remoteLogin, let ip = self.bundle.guestIPAddress(self.config) {
                    evidence = await Self.portOpen(ip, 22)
                } else {
                    evidence = !account.remoteLogin && Date().timeIntervalSince(startedAt) > 180
                }
                if evidence {
                    self.markProvisioned()
                    return
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func markProvisioned() {
        guard var account = config.account, !account.provisioned else { return }
        account.provisioned = true
        config.account = account
        try? bundle.saveConfig(config)
        log.write("guest account \(account.username) provisioned")
    }

    /// TCP connect probe (see GuestNetwork.tcpReachable for why it shells out to nc).
    static func portOpen(_ host: String, _ port: UInt16) async -> Bool {
        await Task.detached { GuestNetwork.tcpReachable(host, port: port, timeoutMs: 2000) }.value
    }

    private func restoreSavedState(_ vm: VZVirtualMachine, vzConfig: VZVirtualMachineConfiguration) async throws {
        do {
            try vzConfig.validateSaveRestoreSupport()
            try await vm.restoreMachineStateFrom(url: bundle.savedStateURL)
            try await vm.resume()
            try? FileManager.default.removeItem(at: bundle.savedStateURL)
            try? FileManager.default.removeItem(at: bundle.savedStateUSBMarkerURL)
            log.write("resumed from saved state")
        } catch {
            // Never throw away a suspended session on our own: the failure may be temporary. VZ
            // encrypts saved memory with a Secure Enclave key that is unavailable while the Mac is
            // locked (e.g. a CLI or login-item start). The user can discard the state explicitly.
            log.write("could not resume (\(error.localizedDescription)); saved state kept")
            let reason = Self.screenIsLocked
                ? "the Mac is locked, and macOS only decrypts a saved VM while you're logged in and unlocked. Unlock it and start the VM again."
                : "\(error.localizedDescription) Try again, or discard the saved state to start from disk (anything unsaved inside the VM is lost)."
            throw VitrineError.backend("Could not resume \(bundle.name): \(reason)")
        }
    }

    /// Whether the console session's screen is locked (saved VM state can't be decrypted then).
    static var screenIsLocked: Bool {
        let info = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (info?["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Asks the guest to shut down; force-stops after `timeout`.
    public func stop(timeout: TimeInterval = 30) async {
        // A paused guest can't shut down (its vCPUs don't run): resume it first, or the shutdown
        // request just runs out the clock and the VM is killed without flushing anything.
        if state == .paused {
            do { try await resume() } catch { log.write("could not resume before shutting down: \(error.localizedDescription)") }
        }
        guard let b = backend, state == .running || state == .paused else { return }
        state = .stopping
        if await b.requestStop() {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline, backend === b, !b.hasStopped {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        // Only the run this request was for: another may have started (on either backend) meanwhile.
        if backend === b { await forceStop() }
    }

    public func forceStop() async {
        if let q = qemu {
            state = .stopping
            await q.forceStop() // returns once QEMU and swtpm have exited
            if qemu === q { didStop(error: nil) }
            return
        }
        guard let vm = virtualMachine else { return }
        if vm.canStop { try? await vm.stop() }
        didStop(error: nil)
    }

    // Pause/resume only publish their result if nothing else (stop, suspend) took over meanwhile.
    public func pause() async throws {
        guard let b = backend, state == .running else { return }
        try await b.pause()
        if backend === b, state == .running { state = .paused }
    }

    public func resume() async throws {
        guard let b = backend, state == .paused else { return }
        try await b.resume()
        if backend === b, state == .paused { state = .running }
    }

    /// Saves RAM + device state to the bundle and stops. The next `start()` resumes instantly.
    public func suspend() async throws {
        if config.features.disposable, state == .running || state == .paused {
            throw VitrineError.unsupported("a disposable VM can't be suspended (its changes are discarded when it stops); shut it down instead")
        }
        if let q = qemu, state == .running || state == .paused {
            try checkUSBAllowsSuspend()
            let wasPaused = state == .paused
            state = .suspending
            let unplugged: [USBAttachment]
            do { unplugged = try await unplugAllUSB() } catch {
                await recoverFromAbortedSuspend(error, wasPaused: wasPaused)
                throw error
            }
            do {
                try await q.suspend()
                do { try saveSuspendedUSB(unplugged) } catch {
                    // Not fatal for QEMU (its state doesn't depend on it): the drives just stay out.
                    log.write("could not record the USB attachments to plug back in: \(error.localizedDescription)")
                }
                log.write("suspended (QEMU)")
                didStop(error: nil)
                state = .suspended
            } catch {
                lastError = "Suspend failed: \(error.localizedDescription)"
                log.write("suspend failed: \(error.localizedDescription)")
                if q.isRunning {
                    switch q.suspendFailureState {
                    case .running: state = .running
                    case .paused: state = .paused
                    case .unavailable, nil: state = .error
                    }
                    if state == .running || state == .paused { await replugUSB(unplugged) }
                } else {
                    didStop(error: error) // QEMU died mid-save: don't report a dead VM as running
                }
                throw error
            }
            return
        }
        guard let vz, state == .running || state == .paused else { return }
        let vm = vz.vm
        try checkUSBAllowsSuspend()
        let wasPaused = state == .paused
        state = .suspending
        let unplugged: [USBAttachment]
        do { unplugged = try await unplugAllUSB() } catch {
            await recoverFromAbortedSuspend(error, wasPaused: wasPaused)
            throw error
        }
        do {
            if vm.state == .running { try await vm.pause() }
            try await vm.saveMachineStateTo(url: bundle.savedStateURL)
            // The marker and the attachment list are part of the saved state: if either can't be
            // written (e.g. the disk filled up saving RAM) the save is undone and the VM resumes.
            if vz.hasUSBController {
                guard FileManager.default.createFile(atPath: bundle.savedStateUSBMarkerURL.path, contents: nil) else {
                    throw VitrineError.io("could not write \(bundle.savedStateUSBMarkerURL.lastPathComponent)")
                }
            } else {
                try? FileManager.default.removeItem(at: bundle.savedStateUSBMarkerURL)
            }
            try saveSuspendedUSB(unplugged)
            if vm.canStop { try await vm.stop() }
            log.write("suspended")
            didStop(error: nil)
            state = .suspended
        } catch {
            try? FileManager.default.removeItem(at: bundle.savedStateURL)
            try? FileManager.default.removeItem(at: bundle.savedStateUSBMarkerURL)
            try? FileManager.default.removeItem(at: bundle.suspendedUSBURL)
            if vm.state == .paused { try? await vm.resume() }
            state = vm.state == .running ? .running : .error
            if state == .running { await replugUSB(unplugged) }
            lastError = "Suspend failed: \(error.localizedDescription)"
            throw error
        }
    }

    /// After a suspend was abandoned while unplugging USB: back to running (or, if the backend died
    /// meanwhile — its exit handler ignores exits while suspending — a normal stop), and only then
    /// are the devices that were already unplugged plugged back in.
    private func recoverFromAbortedSuspend(_ error: Error, wasPaused: Bool) async {
        lastError = "Suspend failed: \(error.localizedDescription)"
        let alive = qemu?.isRunning ?? (virtualMachine.map { $0.state == .running || $0.state == .paused } ?? false)
        guard alive else {
            didStop(error: error)
            return
        }
        state = wasPaused ? .paused : .running
        if let e = error as? USBUnplugError { await replugUSB(e.unplugged) }
    }

    /// Re-reads whether a suspended state exists (e.g. after restoring a snapshot).
    public func refreshSavedState() {
        guard state == .stopped || state == .suspended else { return }
        state = hasSavedState ? .suspended : .stopped
    }

    public func discardSavedState() {
        guard state == .suspended else { return }
        bundle.discardSavedState()
        state = .stopped
    }

    /// Adds a line to the VM log (for app-level events such as Dock clicks).
    public func note(_ message: String) { log.write(message) }

    // MARK: Live configuration

    /// Replaces shared folders while the VM runs (virtiofs share is hot-swappable).
    public func updateShares(_ shares: [VMConfig.SharedDirectory]) throws {
        // Start from the saved configuration: another process (vitrinectl set) may have changed
        // other settings since this controller loaded it.
        var latest = (try? bundle.loadConfig()) ?? config
        latest.shares = shares
        if latest.guestOS == .windows { latest.assignDriveLetters() }
        try latest.validate(bundle: bundle)
        try bundle.saveConfig(latest)
        config = latest
        try backend?.updateShares(config)
        if let agent { sendShares(to: agent) }
    }

    /// Tells a Windows agent which SMB shares to map: shared folders get drive letters from Z: down.
    private func sendShares(to session: AgentSession) {
        guard let qemu, config.guestOS == .windows else { return }
        // Folders shared before letters were remembered get theirs now, and keep them.
        var withLetters = (try? bundle.loadConfig()) ?? config
        if withLetters.assignDriveLetters() {
            do { try saveConfig(withLetters) } catch { log.write("could not save drive letters: \(error.localizedDescription)") }
        }
        guard let samba = qemu.samba else {
            if let reason = qemu.sambaUnavailableReason { log.write("shared folders unavailable: \(reason)") }
            return
        }
        guard session.guestHello?.capabilities.contains("shares") == true else { return }
        for share in config.shares {
            if let reason = QEMUMachine.unservableReason(share, bundle: bundle) {
                log.write("shared folder \"\(share.name)\" skipped: \(reason)")
            }
        }
        let message = MountShares(server: SambaServer.guestAddress, username: samba.username, password: samba.password,
                                  shares: Self.driveMappings(QEMUMachine.smbShares(config: config, bundle: bundle)))
        if session.send(.mountShares(message)) {
            log.write("sent \(message.shares.count) share(s) to the guest")
        }
    }

    /// Drive letters Z, Y, X … for shared folders; the drag-and-drop share stays letterless.
    /// Each shared folder keeps its own drive letter (see VMConfig.assignDriveLetters); one without
    /// gets the first free letter from Z: down. The transfer share gets none.
    nonisolated static func driveMappings(_ shares: [SambaServer.Share]) -> [MountShares.Share] {
        var used = Set(shares.compactMap(\.letter))
        return shares.map { s in
            var letter: String?
            if s.name != SambaServer.transferShare {
                letter = s.letter ?? VMConfig.shareDriveLetters.first { !used.contains($0) }
                if let letter { used.insert(letter) }
            }
            return MountShares.Share(name: s.name, letter: letter, readOnly: s.readOnly)
        }
    }

    /// Re-reads the configuration while the VM isn't running, picking up changes made outside
    /// this process (vitrinectl writes a new VM's configuration in more than one step).
    public func reloadConfig() {
        guard state == .stopped || state == .suspended || state == .error,
              let fresh = try? bundle.loadConfig(), fresh != config else { return }
        config = fresh
    }

    public func updatePortForwards(_ change: (inout [VMConfig.PortForward]) -> Void) throws {
        func edit() throws {
            var fresh = try bundle.loadConfig()
            change(&fresh.network.portForwards)
            try saveConfig(fresh)
        }
        if bundle.holdsRunLock, state == .running || state == .paused {
            try edit()
        } else {
            try bundle.withExclusiveLock(edit)
        }
    }

    public func saveConfig(_ new: VMConfig) throws {
        try new.validate(bundle: bundle)
        try bundle.saveConfig(new)
        config = new
    }

    /// Resizes the guest display (used by Coherence to match the host screen).
    public func reconfigureDisplay(widthPixels: Int, heightPixels: Int) {
        reconfigureDisplay(widthPixels: widthPixels, heightPixels: heightPixels, pixelsPerInch: config.display.pixelsPerInch)
    }

    /// Retries while a freshly attached view isn't presenting the display yet ("not at this time").
    public func reconfigureDisplayWhenReady(widthPixels: Int, heightPixels: Int, pixelsPerInch: Int,
                                            delays: [Double] = [0.3, 1, 2, 2, 3, 3, 4, 5, 5, 5]) {
        guard let delay = delays.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.state == .running else { return }
            if !self.reconfigureDisplay(widthPixels: widthPixels, heightPixels: heightPixels, pixelsPerInch: pixelsPerInch) {
                self.reconfigureDisplayWhenReady(widthPixels: widthPixels, heightPixels: heightPixels,
                                                 pixelsPerInch: pixelsPerInch, delays: Array(delays.dropFirst()))
            }
        }
    }

    /// Requests a new guest display mode. The guest may ignore it; the size it actually adopted is
    /// logged two seconds later.
    @discardableResult
    public func reconfigureDisplay(widthPixels: Int, heightPixels: Int, pixelsPerInch: Int) -> Bool {
        guard let display = virtualMachine?.graphicsDevices.first?.displays.first else { return false }
        // VZ reports "not at this time" when asked for the size the display already has.
        if Int(display.sizeInPixels.width) == widthPixels && Int(display.sizeInPixels.height) == heightPixels {
            log.write("display already \(widthPixels)x\(heightPixels)")
            return true
        }
        do {
            if config.guestOS == .macOS {
                let cfg = VZMacGraphicsDisplayConfiguration(widthInPixels: widthPixels, heightInPixels: heightPixels,
                                                            pixelsPerInch: pixelsPerInch)
                try display.reconfigure(configuration: cfg)
            } else {
                try display.reconfigure(sizeInPixels: CGSize(width: widthPixels, height: heightPixels))
            }
            log.write("display reconfigure requested: \(widthPixels)x\(heightPixels) @\(pixelsPerInch)ppi")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak display] in
                guard let display else { return }
                self?.log.write("display now \(Int(display.sizeInPixels.width))x\(Int(display.sizeInPixels.height))")
            }
            return true
        } catch {
            log.write("display reconfigure to \(widthPixels)x\(heightPixels) failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Guest agent

    @Published public private(set) var agentInstallStatus: String?

    /// Once SSH answers after the provisioned first boot, finish macOS setup
    /// (so cold boots skip Setup Assistant) and install the agent — both over SSH, automatically.
    private func autoInstallAgentIfNeeded() {
        guard let account = config.account, account.remoteLogin else { return }
        let isMac = config.guestOS == .macOS
        let needsFinalize = isMac && account.setupFinalized != true
        let needsAgent = account.agentInstalled != true && AgentInstaller.agentPackage(for: config.guestOS) != nil
        guard needsFinalize || needsAgent else { return }
        Task { [weak self] in
            let deadline = Date().addingTimeInterval(600)
            var finalized = !needsFinalize
            while Date() < deadline {
                guard let self, self.state == .running else { return }
                guard let t = try? AgentInstaller.target(for: self.bundle), await Self.portOpen(t.host, 22) else {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    continue
                }
                do {
                    if !finalized {
                        try await AgentInstaller.finalizeSetup(in: self.bundle)
                        finalized = true
                        self.updateAccount { $0.setupFinalized = true }
                        self.log.write("macOS setup marked complete")
                    }
                    if needsAgent && self.agent == nil {
                        self.agentInstallStatus = "Installing Vitrine Agent…"
                        try await AgentInstaller.install(into: self.bundle)
                        self.log.write("agent installed over SSH")
                        self.agentInstallStatus = "Vitrine Agent installed — for seamless mode, choose Actions ▸ Allow Vitrine Agent Control…"
                    }
                    if needsAgent { self.recordAgentInstalled() }
                    return
                } catch {
                    // sshd may accept connections before login completes; retry.
                    self.agentInstallStatus = nil
                    self.log.write("post-provisioning attempt failed: \(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                }
            }
        }
    }

    private func updateAccount(_ change: (inout VMConfig.GuestAccount) -> Void) {
        guard var account = config.account else { return }
        change(&account)
        config.account = account
        try? bundle.saveConfig(config)
    }

    private func recordAgentInstalled() {
        guard var account = config.account else { return }
        account.agentInstalled = true
        config.account = account
        try? bundle.saveConfig(config)
    }

    private func startAgentConnector() {
        agentRetryTask?.cancel()
        // Leaves the agent's single connection free for diagnostics (vitrinectl agent probe).
        if ProcessInfo.processInfo.environment["VITRINE_NO_AGENT"] == "1" { return }
        agentRetryTask = Task { [weak self] in
            var delay: UInt64 = 1_000_000_000
            while !Task.isCancelled {
                guard let self, self.isLive else { return }
                if self.agent == nil, self.state == .running {
                    if let channel = await self.backend?.connectAgent() {
                        self.attachAgent(channel)
                        delay = 1_000_000_000
                    } else {
                        self.qemu?.agentTransportFailed() // e.g. nothing forwarded: try the other one
                        delay = min(delay * 2, 8_000_000_000)
                    }
                }
                try? await Task.sleep(nanoseconds: delay)
            }
        }
    }

    private func attachAgent(_ channel: AgentChannel) {
        // Over TCP (older Windows agents) the agent only accepts a host that knows the VM's token.
        let overTCP = qemu.map { $0.agentTCPPort != nil && !$0.agentOverSerial } ?? false
        let token = overTCP ? try? bundle.agentToken() : nil
        // Emulated x86_64 guests (QEMU TCG) answer pings late under load; don't drop them for it.
        let emulated = qemu != nil && config.effectiveArchitecture == .x86_64
        let session = AgentSession(channel: channel, token: token, pongTimeout: emulated ? 60 : 10)
        var handshook = false
        session.onStateChange = { [weak self, weak session] st in
            guard let self else { return }
            switch st {
            case .connecting: self.agentConnection = .connecting
            case .ready(let hello):
                handshook = true
                self.agentConnection = .connected(os: hello.os, agentVersion: hello.agentVersion)
                self.log.write("agent connected: \(hello.os) agent \(hello.agentVersion)")
                // Windows installs its agent during Setup, not over SSH: note it once it answers.
                if self.config.account != nil, self.config.account?.agentInstalled != true { self.recordAgentInstalled() }
                if self.config.features.clipboard, let session { self.startClipboardSync(session) }
                if let session {
                    self.sendShares(to: session)
                    self.syncGuestClock(session)
                }
                self.noteWindowsSetupProgress()
            case .closed(let reason):
                self.agentConnection = .disconnected(reason: reason)
                if !handshook { self.qemu?.agentTransportFailed() }
                if self.agent === session {
                    self.agent = nil
                    self.guestStats = nil
                    self.camera.stop(tellGuest: false)
                    self.bluetooth.stop(tellGuest: false)
                    self.pasteboard?.stop()
                    self.pasteboard = nil
                }
            }
        }
        session.onLog = { [weak self] in self?.log.write($0) }
        session.onClipboard = { [weak self] content in self?.pasteboard?.apply(content) }
        session.onGuestStats = { [weak self] stats in self?.guestStats = stats }
        session.onCameraStatus = { [weak self, weak session] status in
            guard let self, let session, self.agent === session else { return }
            self.camera.statusArrived(status)
        }
        session.onBluetoothStatus = { [weak self, weak session] status in
            guard let self, let session, self.agent === session else { return }
            self.bluetooth.statusArrived(status)
        }
        session.onBluetoothHCI = { [weak self, weak session] packet in
            guard let self, let session, self.agent === session else { return }
            self.bluetooth.device?.receive(packet)
        }
        session.onGuestNetwork = { [weak self] info in
            guard let self else { return }
            // The first IPv4 address of the adapter Vitrine gave the VM, for networks the Mac's
            // DHCP lease file doesn't cover; else what the guest's frames showed.
            self.bundle.recordGuestIP(info.ipv4(forMAC: self.config.network.macAddress)?.first
                                      ?? self.networkLink?.guestAddress?.address)
        }
        agent = session
        agentConnection = .connecting
        session.start()
    }

    /// The guest clock stood still while suspended; also aligns its time zone. Only agents that
    /// announce "time" understand the message (older ones drop the connection on unknown types).
    func syncGuestClock(_ session: AgentSession) {
        guard config.features.timeSync, session.guestHello?.capabilities.contains("time") == true else { return }
        session.send(.timeSync(TimeSync(unixMillis: Int64(Date().timeIntervalSince1970 * 1000),
                                        timeZone: TimeZone.current.identifier,
                                        windowsTimeZone: WindowsTimeZone.current)))
    }

    /// Whether dropped files can be delivered (agent supports it).
    /// Windows guests take files over the SMB transfer share, so not without a running Samba.
    public var acceptsFileDrops: Bool {
        guard agent?.guestHello?.capabilities.contains("files") == true else { return false }
        if let qemu, config.guestOS == .windows { return qemu.samba != nil }
        return true
    }

    /// Copies files into the transfer share (APFS clones, so instant) and asks the agent to take them.
    public func dropFiles(_ urls: [URL], guestPoint: CGPoint? = nil) {
        do { try sendFiles(urls, guestPoint: guestPoint) } catch {
            log.write("file drop failed: \(error.localizedDescription)")
        }
    }

    /// `dropFiles`, reporting failures (staging, or the agent channel refusing the message).
    public func sendFiles(_ urls: [URL], guestPoint: CGPoint? = nil) throws {
        guard let agent, acceptsFileDrops else { throw VitrineError.unsupported("the guest agent doesn't take files") }
        pruneTransfers()
        let batch = UUID().uuidString
        let dir = bundle.transferDirectory.appendingPathComponent(batch, isDirectory: true)
        var names: [String] = []
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var used = Set<String>()
            for url in urls {
                // Two dropped items can share a name (from different folders): number the later ones.
                var name = url.lastPathComponent, n = 2
                while used.contains(name.lowercased()) {
                    let ext = url.pathExtension, base = url.deletingPathExtension().lastPathComponent
                    name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
                    n += 1
                }
                used.insert(name.lowercased())
                let dest = dir.appendingPathComponent(name)
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    try FileManager.default.copyItem(at: url, to: dest)
                } else {
                    try DiskImage.clone(url, to: dest)
                }
                names.append("\(batch)/\(name)")
            }
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        guard agent.send(.fileDrop(FileDrop(files: names, x: guestPoint.map { Double($0.x) }, y: guestPoint.map { Double($0.y) }))) else {
            try? FileManager.default.removeItem(at: dir)
            throw VitrineError.backend("the guest agent disconnected")
        }
        log.write("dropped \(names.count) file(s) into the guest")
    }

    /// Batches the guest has had a day to copy are removed (Windows reads them over a read-only
    /// share and can't delete them itself; APFS clones only cost space once the originals change).
    /// A day, not an hour: an emulated guest can take hours to copy a large folder.
    func pruneTransfers(olderThan age: TimeInterval = 86_400) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: bundle.transferDirectory, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for item in items where UUID(uuidString: item.lastPathComponent) != nil {
            if let created = try? item.resourceValues(forKeys: [.creationDateKey]).creationDate, created < cutoff {
                try? fm.removeItem(at: item)
            }
        }
    }

    /// Host ⇄ guest clipboard through the agent (text, RTF, HTML, images).
    private(set) var pasteboard: PasteboardSync?

    private func startClipboardSync(_ session: AgentSession) {
        pasteboard?.stop()
        let sync = PasteboardSync()
        sync.onLocalChange = { [weak session] content in session?.send(.clipboard(content)) }
        sync.start()
        pasteboard = sync
    }

    /// Whether a connected macOS agent still lacks a permission seamless mode needs (Screen
    /// Recording, Accessibility), which `requestAgentPermissions` can ask the guest user for.
    public var agentLacksPermissions: Bool {
        guard config.guestOS == .macOS, let caps = agent?.guestHello?.capabilities else { return false }
        return !caps.contains("coherence") || !caps.contains("input")
    }

    /// Has the agent show the guest's permission prompts, at the user's request: agents no longer
    /// ask at every login. False when it can't (no agent, or one too old to know the request).
    @discardableResult
    public func requestAgentPermissions() -> Bool {
        guard let session = agent, session.guestHello?.capabilities.contains("permissions") == true else { return false }
        log.write("asking the guest to allow the agent's permissions")
        return session.send(.requestPermissions)
    }

    /// Turns clipboard sharing on or off now and for later runs.
    public func setClipboardSharing(_ on: Bool) throws {
        var c = config
        c.features.clipboard = on
        try saveConfig(c)
        if on, let session = agent, session.isReady {
            if pasteboard == nil { startClipboardSync(session) }
        } else {
            pasteboard?.stop()
            pasteboard = nil
        }
    }

    /// Unplugs or plugs back the VM's network cable while it runs: the guest sees its link go down,
    /// as with a pulled Ethernet cable, and keeps its configuration.
    public func setNetworkCable(connected: Bool) async throws {
        guard state == .running || state == .paused, config.network.isConnected, let b = backend else { return }
        let generation = runGeneration
        guard try await b.setNetworkCable(connected: connected) else { return }
        // The VM may have stopped (and another run started) while the backend answered.
        guard runGeneration == generation, backend === b else { return }
        networkCableDisconnected = !connected
        log.write("network cable \(connected ? "plugged in" : "unplugged")")
    }

    // MARK: Camera

    /// Sharing the Mac's camera with the guest, for this run only. On, frames reach the guest's
    /// virtual camera at the device (e.g. /dev/video0); `.failed` with `guestSide` true means the
    /// guest has no virtual camera yet, which `installCameraSupport` sets up.
    public var cameraSharing: GuestShareState { camera.state }
    private lazy var camera = GuestShare<CameraCapture>(
        owner: self, name: "camera", capability: "camera", refusal: "the guest couldn't take the camera",
        start: { [weak self] share, session in try await self?.startCamera(share, session) },
        stop: { cam, session in
            // Synchronously, so no frame from the capture queue can follow cameraStop.
            cam.stopDelivering()
            Task.detached { cam.stop() }
            session?.send(.cameraStop)
        },
        install: { [bundle] in try await AgentInstaller.installCameraSupport(in: bundle) },
        installRestartsAgent: { [weak self] in self?.config.guestOS == .macOS })

    /// The guest's agent can take the Mac's camera (Linux agents, and macOS agents carrying the
    /// Vitrine Camera extension).
    public var guestTakesCamera: Bool { camera.offered }

    public func setCameraSharing(_ on: Bool) async { await camera.set(on) }

    private func startCamera(_ share: GuestShare<CameraCapture>, _ session: AgentSession) async throws {
        guard await CameraCapture.requestAccess() else { throw CameraCapture.Failure.accessDenied }
        // Frames go straight from the capture queue to the channel; when the guest falls behind by
        // more than two frames, newer ones are dropped rather than queued.
        let cam = CameraCapture { [weak session] frame in
            guard let session, session.pendingSendBytes < 2 * frame.data.count + (1 << 20) else { return }
            session.send(.cameraFrame(frame))
        }
        cam.onFormat = { [weak self] format in
            Task { @MainActor in self?.log.write("camera delivers \(format)") }
        }
        let size = try await Task.detached { try cam.prepare() }.value
        guard share.adopt(cam, for: session) else { return }
        session.send(.cameraStart(CameraStart(width: size.width, height: size.height, fps: 30)))
        await Task.detached { cam.run() }.value
        // The guest may have refused (or the switch been turned off) while the camera started;
        // the stop then raced the start, so stop again now that it's running.
        guard share.device === cam else {
            await Task.detached { cam.stop() }.value
            return
        }
        log.write("camera shared at \(size.width)×\(size.height)")
    }

    /// Sets up the guest's virtual camera over SSH (v4l2loopback in Linux guests; in macOS guests,
    /// moves the agent to /Applications so it may add its camera extension), then shares the camera.
    public func installCameraSupport() async throws { try await camera.install() }

    // MARK: Bluetooth

    /// Sharing the Mac's Bluetooth LE with the guest (experimental), for this run only. On, the
    /// guest's kernel has the emulated controller as the device (e.g. hci0); `.failed` with
    /// `guestSide` true means the guest has no bridge yet, which `installBluetoothSupport` sets up.
    public var bluetoothSharing: GuestShareState { bluetooth.state }
    private lazy var bluetooth = GuestShare<BluetoothBridge>(
        owner: self, name: "bluetooth", capability: "bluetooth", refusal: "the guest couldn't take the Bluetooth controller",
        start: { [weak self] share, session in try self?.startBluetooth(share, session) },
        stop: { bridge, session in
            session?.send(.bluetoothStop)
            Task.detached { bridge.stop() }
        },
        install: { [bundle] in try await AgentInstaller.installBluetoothSupport(in: bundle) },
        onReady: { [weak self] status in self?.log.write("bluetooth shared as \(status.device ?? "a controller")") })

    /// The guest's agent can take an emulated Bluetooth controller (Linux agents).
    public var guestTakesBluetooth: Bool { bluetooth.offered }

    public func setBluetoothSharing(_ on: Bool) async { await bluetooth.set(on) }

    private func startBluetooth(_ share: GuestShare<BluetoothBridge>, _ session: AgentSession) throws {
        guard !BluetoothBridge.accessDenied else {
            throw ShareUnavailable("Vitrine isn't allowed to use Bluetooth. Allow it in System Settings > Privacy & Security > Bluetooth.")
        }
        // The controller exists before the guest's kernel sees it: its first commands come at once.
        let bridge = BluetoothBridge(seed: config.id, send: { [weak session] packet in
            session?.send(.bluetoothHCI(packet))
        }, unavailable: { [weak self, weak session] reason in
            Task { @MainActor in
                guard let self, let session, self.agent === session, self.bluetooth.device != nil else { return }
                self.bluetooth.fail(reason, guestSide: false)
            }
        })
        // Nothing above waits, so the switch and the agent are as they were when it was turned on.
        guard share.adopt(bridge, for: session) else { return }
        session.send(.bluetoothStart)
    }

    /// Sets up the guest's Bluetooth bridge over SSH (BlueZ and a root service), then shares.
    public func installBluetoothSupport() async throws { try await bluetooth.install() }

    // MARK: Teardown

    private func didStop(error: Error?) {
        tearDownRuntime()
        agentRetryTask?.cancel()
        agentRetryTask = nil
        camera.stop(tellGuest: false)
        bluetooth.stop(tellGuest: false)
        agent?.close()
        agent = nil
        agentConnection = .notConnected
        guestStats = nil
        networkCableDisconnected = false
        vz = nil
        qemu = nil
        endDisposableRun()
        bundle.releaseRunLock()
        if let error {
            fail(error)
        } else {
            state = hasSavedState ? .suspended : .stopped
            log.write("stopped")
            // A suspended VM keeps its devices (the saved state expects them).
            if !hasSavedState { ejectMediaIfSetupDone() }
        }
    }

    private func fail(_ error: Error) {
        tearDownRuntime()
        lastError = error.localizedDescription
        log.write("error: \(error.localizedDescription)")
        vz = nil
        qemu = nil
        if bundle.holdsRunLock { endDisposableRun() }
        bundle.releaseRunLock()
        // A VM whose start failed but still has its saved memory stays resumable (or discardable).
        state = hasSavedState ? .suspended : .error
    }
}

extension VirtualMachineController: VZVirtualMachineDelegate {
    // Callbacks from a VM instance that has since been replaced (e.g. the restore → cold-boot
    // fallback) must not tear down the current one.
    nonisolated public func guestDidStop(_ vm: VZVirtualMachine) {
        MainActor.assumeIsolated {
            guard self.virtualMachine === vm, self.state != .suspending else { return }
            self.didStop(error: nil)
        }
    }

    nonisolated public func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) {
        MainActor.assumeIsolated {
            guard self.virtualMachine === vm else { return }
            self.didStop(error: error)
        }
    }
}

/// Append-only per-VM log.
final class VMLog {
    let url: URL
    private let formatter = ISO8601DateFormatter()
    init(url: URL) { self.url = url }
    func write(_ line: String) {
        let text = "\(formatter.string(from: Date())) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd(); try? h.write(contentsOf: Data(text.utf8)); try? h.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }
}

// MARK: Disposable mode

extension VirtualMachineController {
    /// Settles a disposable run left over from a crash, then records this run's baseline.
    /// Called with the run lock held, before anything touches the disks.
    func beginDisposableRunIfNeeded() throws {
        let session = DisposableSession(bundle: bundle)
        if session.isPending {
            let discarded = try session.end()
            log.write(discarded ? "rolled back an unfinished disposable run" : "kept the changes of an unfinished run (disposable mode is off)")
            config = try bundle.loadConfig()
        }
        if config.features.disposable {
            try session.begin()
            log.write("disposable run: changes are discarded when the VM stops")
        }
    }

    /// Discards a disposable run's changes (run lock still held).
    func endDisposableRun() {
        let session = DisposableSession(bundle: bundle)
        guard session.isPending else { return }
        do {
            if try session.end() { log.write("discarded the disposable run's changes") }
            if let reloaded = try? bundle.loadConfig() { config = reloaded }
        } catch {
            // The marker stays, so the next start retries the rollback before booting.
            log.write("error: could not discard the disposable run yet: \(error.localizedDescription)")
            lastError = "Couldn't discard this disposable run's changes yet; they will be discarded before the next start. \(error.localizedDescription)"
        }
    }
}
