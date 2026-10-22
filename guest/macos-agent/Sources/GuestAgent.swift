import AppKit
import VitrineAgentProtocol

/// Serves one host connection at a time. Main-thread confined.
final class GuestAgent {
    static let version = "0.1.0"

    private let listener: Listener
    private var channel: AgentChannel?
    private var streamer: ScreenStreamer?
    private let pasteboard = PasteboardSync()
    private let input = InputInjector()
    private var windows: [WindowInfo] = []
    private var windowTimer: Timer?
    private var coherence = false
    private var fps = 60
    private var screenChangeWork: DispatchWorkItem?
    private var networkTimer: Timer?
    private var statsTimer: Timer?
    private var permissionTimer: Timer?
    private var lastNetwork: GuestNetworkInfo?
    private lazy var camera: CameraSink = {
        let c = CameraSink()
        c.onLog = { [weak self] in self?.log($0) }
        return c
    }()
    private let verbose: Bool

    init(listener: Listener, verbose: Bool) {
        self.listener = listener
        self.verbose = verbose
    }

    func log(_ s: String) {
        FileHandle.standardError.write(Data("vitrine-agent: \(s)\n".utf8))
        channel?.send(.log(s))
    }

    func run() throws {
        try listener.open()
        log("listening (screen recording: \(ScreenStreamer.hasPermission ? "granted" : "missing"), " +
            "accessibility: \(InputInjector.isTrusted ? "granted" : "missing"))")
        // Screen Recording and Accessibility are asked for only when the user asks the host app to
        // (requestPermissions), not at every login: a VM only driven from the host never needs them.

        pasteboard.onLocalChange = { [weak self] content in self?.channel?.send(.clipboard(content)) }
        pasteboard.start()

        // The host resizes the guest display when entering Coherence: re-announce geometry and
        // restart capture at the new size.
        // A resolution change posts this several times in a row; coalesce them into one restart.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.screenChangeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.channel != nil else { return }
                self.channel?.send(.displayInfo(WindowTracker.displayInfo()))
                if self.coherence { self.setCoherence(true, fps: self.fps) }
            }
            self.screenChangeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }

        let accept = Thread { [weak self] in
            while let self {
                do {
                    let fd = try self.listener.accept()
                    DispatchQueue.main.async { self.attach(fd) }
                } catch {
                    FileHandle.standardError.write(Data("vitrine-agent: \(error)\n".utf8))
                    sleep(1)
                }
            }
        }
        accept.name = "vitrine.agent.accept"
        accept.start()
    }

    private func attach(_ fd: Int32) {
        // A new host connection replaces the old one (e.g. after the host app restarted).
        detach()
        let ch = AgentChannel(fileDescriptor: fd)
        channel = ch
        ch.start(callbackQueue: .main, onMessage: { [weak self, weak ch] in
                     // Messages still queued from a replaced connection are dropped.
                     guard let self, let ch, self.channel === ch else { return }
                     self.handle($0)
                 },
                 onClose: { [weak self, weak ch] _ in
                     guard let self, self.channel === ch else { return }
                     self.log("host disconnected")
                     self.detach()
                 })
        var caps = ["clipboard", "files", "apps", "permissions"]
        if ScreenStreamer.hasPermission { caps.append("coherence") }
        if InputInjector.isTrusted { caps.append("input") }
        if CameraSink.isBundled { caps.append("camera") }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        ch.send(.hello(Hello(role: "guest", os: "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
                             agentVersion: Self.version, capabilities: caps)))
        ch.send(.displayInfo(WindowTracker.displayInfo()))
        log("host connected")
    }

    private func detach() {
        networkTimer?.invalidate()
        networkTimer = nil
        statsTimer?.invalidate()
        statsTimer = nil
        lastNetwork = nil
        camera.stop()
        input.releaseAll()
        setCoherence(false, fps: 0)
        channel?.close()
        channel = nil
    }

    private func handle(_ message: AgentMessage) {
        switch message {
        case .hello(let h):
            if verbose { log("host hello: \(h.os) caps=\(h.capabilities)") }
            if h.capabilities.contains("network") { startNetworkReports() }
            if h.capabilities.contains("stats") { startStatsReports() }
        case .ping(let n):
            channel?.send(.pong(n))
        case .clipboard(let content):
            pasteboard.apply(content)
        case .setCoherence(let req):
            setCoherence(req.enabled, fps: req.maxFPS)
        case .pointer(let e):
            input.pointer(e)
        case .key(let e):
            input.key(e)
        case .windowAction(let a):
            input.perform(a, windows: windows)
            publishWindows(force: true)
        case .fileDrop(let drop):
            FileDropHandler.handle(drop) { [weak self] in self?.log($0) }
        case .appIconRequest(let r):
            channel?.send(.appIcon(AppCatalogProvider.icon(forKey: r.key)))
        case .appCatalogRequest(let r):
            // Rendering a few hundred icons takes a moment; the reply goes out when done.
            let ch = channel
            DispatchQueue.global(qos: .utility).async {
                let catalog = AppCatalogProvider.catalog(iconSize: min(max(r.iconSize, 0), 512))
                DispatchQueue.main.async { ch?.send(.appCatalog(catalog)) }
            }
        case .launchApp(let l):
            AppCatalogProvider.launch(l.id) { [weak self] in self?.log($0) }
        case .cameraStart(let r):
            channel?.send(.cameraStatus(camera.start(r)))
        case .cameraFrame(let f):
            camera.frame(f)
        case .cameraStop:
            camera.stop()
        case .requestPermissions:
            requestPermissions()
        case .pong, .windowList, .frame, .displayInfo, .log, .mountShares, .appIcon, .appCatalog, .timeSync, .guestNetwork, .guestStats,
             .cameraStatus, .bluetoothStart, .bluetoothHCI, .bluetoothStop, .bluetoothStatus:
            break
        }
    }

    /// Shows the system prompts for whatever is missing, then watches for the user's answer: the
    /// host learns what the agent may do from its hello, so once a permission is granted the agent
    /// exits and launchd starts it again (KeepAlive), which reconnects with the new capabilities.
    private func requestPermissions() {
        let before = (screen: ScreenStreamer.hasPermission, input: InputInjector.isTrusted)
        guard !before.screen || !before.input else { return log("permissions already granted") }
        log("asking for \([before.screen ? nil : "Screen Recording", before.input ? nil : "Accessibility"].compactMap { $0 }.joined(separator: " and "))")
        // macOS shows each prompt once per app; asked again, open the list to switch it on in instead.
        let defaults = UserDefaults.standard
        let askedKey = "askedPermissions"
        let asked = Set(defaults.stringArray(forKey: askedKey) ?? [])
        if !before.screen && asked.contains("screen") {
            openPrivacyPane("Privacy_ScreenCapture")
        } else if !before.input && asked.contains("input") {
            openPrivacyPane("Privacy_Accessibility")
        } else {
            if !before.input { InputInjector.requestTrust() }
            if !before.screen { CGRequestScreenCaptureAccess() }
        }
        defaults.set(Array(asked.union([before.screen ? nil : "screen", before.input ? nil : "input"].compactMap { $0 })), forKey: askedKey)
        permissionTimer?.invalidate()
        let deadline = Date().addingTimeInterval(600)
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            if InputInjector.isTrusted != before.input || ScreenStreamer.hasPermission != before.screen {
                self?.log("permissions changed; restarting to offer them")
                exit(0)
            }
            if Date() > deadline { timer.invalidate() }
        }
    }

    /// Opens System Settings ▸ Privacy & Security at one permission's list of apps.
    private func openPrivacyPane(_ anchor: String) {
        log("opening System Settings at \(anchor)")
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Sends the interface list now and whenever it changes (DHCP renewals, network switches).
    private func startNetworkReports() {
        networkTimer?.invalidate()
        lastNetwork = nil
        let report = { [weak self] in
            guard let self else { return }
            let now = NetworkReporter.snapshot()
            guard now != self.lastNetwork else { return }
            self.lastNetwork = now
            self.channel?.send(.guestNetwork(now))
        }
        report()
        networkTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in report() }
    }

    /// CPU, memory and disk use every few seconds, for the host's status bar.
    private func startStatsReports() {
        statsTimer?.invalidate()
        let reporter = StatsReporter()
        _ = reporter.snapshot() // first CPU sample
        statsTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.channel?.send(.guestStats(reporter.snapshot()))
        }
    }

    private func setCoherence(_ enabled: Bool, fps: Int) {
        windowTimer?.invalidate()
        windowTimer = nil
        if !enabled {
            if coherence { log("coherence off") }
            coherence = false
            let s = streamer
            streamer = nil
            Task { await s?.stop() }
            return
        }
        guard let ch = channel else { return }
        coherence = true
        self.fps = fps
        let previous = streamer
        Task { await previous?.stop() }
        let s = ScreenStreamer(send: { [weak ch] in ch?.send($0) ?? false },
                               pendingBytes: { [weak ch] in ch?.pendingSendBytes ?? 0 })
        s.log = { [weak self] msg in DispatchQueue.main.async { self?.log(msg) } }
        streamer = s
        Task { @MainActor in
            do { try await s.start(maxFPS: fps) } catch { self.log("capture failed: \(error.localizedDescription)") }
            // Coherence was turned off or restarted while capture was starting: don't leave it running.
            if self.streamer !== s { await s.stop() }
        }
        ch.send(.displayInfo(WindowTracker.displayInfo()))
        publishWindows(force: true)
        windowTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.publishWindows(force: false)
        }
    }

    private func publishWindows(force: Bool) {
        let now = WindowTracker.snapshot()
        guard force || now != windows else { return }
        windows = now
        channel?.send(.windowList(WindowList(windows: now)))
    }
}
