import Foundation
import VitrineAgentProtocol

/// Host side of one guest-agent connection: handshake, keepalive, and fan-out of guest state.
///
/// Threading: every callback and all state (`state`, `windows`, `display`) stays on the main queue.
/// The one exception is frame payloads — `.frame` messages are handed to `frameQueue`, which does the
/// LZ4 decode and the copy into the IOSurface there and only then hops back to main with the dirty
/// rect. Decoding a 1080p band on the main thread costs several milliseconds per frame and starves
/// the UI; `GuestFramebuffer` is internally locked so this is safe.
public final class AgentSession {
    public enum State: Equatable {
        case connecting
        case ready(Hello)
        case closed(String?)
    }

    public static let hostAgentVersion = "0.2.1"

    public private(set) var state: State = .connecting { didSet { onStateChange?(state) } }
    public private(set) var windows: [WindowInfo] = []
    public private(set) var display: DisplayInfo?
    public let framebuffer = GuestFramebuffer()

    public var onStateChange: ((State) -> Void)?
    public var onWindowsChanged: (([WindowInfo]) -> Void)?
    public var onDisplayChanged: ((DisplayInfo) -> Void)?
    /// Called after a frame update is applied, with the dirty rect in pixels.
    public var onFrame: ((Rect) -> Void)?
    public var onClipboard: ((ClipboardContent) -> Void)?
    public var onLog: ((String) -> Void)?
    public var onAppIcon: ((AppIcon) -> Void)?
    public var onAppCatalog: ((AppCatalog) -> Void)?
    public var onGuestNetwork: ((GuestNetworkInfo) -> Void)?
    public var onGuestStats: ((GuestStats) -> Void)?
    public var onCameraStatus: ((CameraStatus) -> Void)?
    public var onBluetoothStatus: ((BluetoothStatus) -> Void)?
    /// HCI packets from the guest's Bluetooth stack (H4 framing).
    public var onBluetoothHCI: ((Data) -> Void)?
    /// The guest's interfaces as last reported by the agent.
    public private(set) var guestNetwork: GuestNetworkInfo?

    private let channel: AgentChannel
    /// Serial queue for frame decode + surface writes. Serial so updates apply in arrival order and
    /// the surface lock is never contended by two decoders; `.userInteractive` because a frame that
    /// misses its deadline is a visible stutter.
    private let frameQueue: DispatchQueue
    private let maxPendingFrameBytes: Int
    private let maxPendingFrameCount: Int
    // The channel bounds delivery to main; these bounds follow payloads through asynchronous decode.
    private let frameBudgetLock = NSLock()
    private var pendingFrameBytes = 0
    private var pendingFrameCount = 0
    private var framesCancelled = false
    private var pingTimer: Timer?
    /// Keepalive times are on a monotonic clock (`now()`): wall-clock changes must not look like
    /// a silent guest.
    private var lastPong: TimeInterval = 0
    /// When the keepalive last ran (or was started); a long gap means the timer was starved, not the guest.
    private var lastKeepalive: TimeInterval?
    private var pingNonce: UInt64 = 0
    /// Round-trip latency of the last ping, for diagnostics.
    public private(set) var latency: TimeInterval?
    private var pingSentAt: [UInt64: TimeInterval] = [:]
    private let now: () -> TimeInterval

    private let token: String?

    /// `token`: the VM's agent secret, for agents reached over TCP (they ignore a missing one only
    /// when the VM wasn't started with it).
    /// How long the guest may go without answering pings before the session is given up.
    private let pongTimeout: TimeInterval
    private let pingInterval: TimeInterval

    /// `pongTimeout`: 10 s suits hardware-accelerated guests; fully emulated ones (x86_64 on Apple
    /// silicon) can stall far longer under load without anything being wrong.
    public convenience init(channel: AgentChannel, token: String? = nil, pongTimeout: TimeInterval = 10) {
        self.init(channel: channel, token: token, pongTimeout: pongTimeout,
                  frameQueue: DispatchQueue(label: "vitrine.agent.frames", qos: .userInteractive),
                  maxPendingFrameBytes: 128 << 20, maxPendingFrameCount: 1024)
    }

    init(channel: AgentChannel, token: String? = nil, pongTimeout: TimeInterval = 10,
         frameQueue: DispatchQueue, maxPendingFrameBytes: Int, maxPendingFrameCount: Int,
         pingInterval: TimeInterval = 2,
         now: @escaping () -> TimeInterval = { TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1e9 }) {
        precondition(maxPendingFrameBytes > 0 && maxPendingFrameCount > 0)
        self.pingInterval = pingInterval
        self.now = now
        self.frameQueue = frameQueue
        self.maxPendingFrameBytes = maxPendingFrameBytes
        self.maxPendingFrameCount = maxPendingFrameCount
        self.channel = channel
        self.token = token
        self.pongTimeout = pongTimeout
    }

    public var isReady: Bool { if case .ready = state { return true } else { return false } }
    public var guestHello: Hello? { if case .ready(let h) = state { return h } else { return nil } }

    public func start() {
        channel.start(callbackQueue: .main, onMessage: { [weak self] in self?.handle($0) },
                      onClose: { [weak self] error in self?.closed(error) })
        channel.send(.hello(Hello(role: "host", os: Self.hostOSDescription, agentVersion: Self.hostAgentVersion,
                                  capabilities: ["coherence", "clipboard", "input", "network", "stats"], token: token)))
        lastPong = now()
        lastKeepalive = lastPong // the first tick is measured from here
        // .common, not just .default: modal panels and alerts, menu tracking and live resize run
        // the main run loop in other modes, and a keepalive that stops there would afterwards
        // mistake its own silence for the guest's.
        let timer = Timer(timeInterval: pingInterval, repeats: true) { [weak self] _ in self?.keepalive() }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    public func close() {
        channel.close()
        closed(nil)
    }

    @discardableResult
    public func send(_ message: AgentMessage) -> Bool { channel.send(message) }

    /// Bytes handed to `send` that haven't reached the guest yet (for dropping video frames).
    public var pendingSendBytes: Int { channel.pendingSendBytes }

    public func setCoherence(_ enabled: Bool, maxFPS: Int = 60) {
        let request = CoherenceRequest(enabled: enabled, maxFPS: maxFPS)
        coherence = enabled ? request : nil
        send(.setCoherence(request))
    }

    /// The last Coherence request, while Coherence is on.
    private var coherence: CoherenceRequest?
    private var repaintScheduled = false

    /// Frames dropped by the framebuffer's resize limit are gone: the guest goes on sending only
    /// what changes. Asking for Coherence again restarts the guest's capture, which starts with a
    /// full frame (every agent version does this). Once the limit has passed, and once per burst.
    private func repaintAfterResizeLimit() {
        guard !repaintScheduled, coherence != nil else { return }
        repaintScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + framebuffer.minResizeInterval) { [weak self] in
            guard let self else { return }
            self.repaintScheduled = false
            guard self.isReady, let request = self.coherence else { return }
            self.send(.setCoherence(request))
        }
    }

    enum KeepaliveAction: Equatable {
        /// Send the next ping.
        case ping
        /// The keepalive itself didn't run for a while (main thread blocked, host asleep): no pings
        /// went out, so the missing pongs say nothing about the guest. Start the timeout over.
        case restartTimeout
        /// Pings went out and the guest didn't answer in time.
        case giveUp
    }

    /// What a keepalive tick at `now` does. Pure, for testing; all times on one monotonic clock.
    static func keepaliveAction(now: TimeInterval, lastTick: TimeInterval?, lastPong: TimeInterval,
                                interval: TimeInterval, pongTimeout: TimeInterval) -> KeepaliveAction {
        if let lastTick, now - lastTick > 2 * interval { return .restartTimeout }
        return now - lastPong > pongTimeout ? .giveUp : .ping
    }

    private func keepalive() {
        let t = now()
        let action = Self.keepaliveAction(now: t, lastTick: lastKeepalive, lastPong: lastPong,
                                          interval: pingInterval, pongTimeout: pongTimeout)
        lastKeepalive = t
        switch action {
        case .giveUp:
            // A virtio-serial chardev accepts connections even when no agent runs in the guest, so a
            // session that never said hello is just "no agent yet" — close quietly and let the caller retry.
            if isReady { onLog?("guest agent stopped responding") }
            close()
            return
        case .restartTimeout:
            lastPong = t
            pingSentAt.removeAll() // their round trips include the stall
        case .ping:
            break
        }
        pingNonce &+= 1
        pingSentAt[pingNonce] = t
        if pingSentAt.count > 8 { pingSentAt.removeAll() }
        send(.ping(pingNonce))
    }

    private func handle(_ message: AgentMessage) {
        if case .closed = state { return } // late deliveries after close
        switch message {
        case .hello(let hello):
            guard hello.protocolVersion == AgentProtocol.version else {
                onLog?("guest agent speaks protocol v\(hello.protocolVersion), host v\(AgentProtocol.version)")
                close()
                return
            }
            lastPong = now()
            state = .ready(hello)
        case .windowList(let list):
            windows = list.windows.filter { $0.frame.isSane }
            onWindowsChanged?(windows)
        case .displayInfo(let info):
            guard info.isSane else {
                onLog?("ignoring implausible display geometry \(info)")
                return
            }
            display = info
            onDisplayChanged?(info)
        case .frame(let update):
            // Never block main or drop incremental dirty rectangles: an overflowing stream must reconnect.
            let cost = update.data.count
            guard reserveFrame(bytes: cost) else {
                channel.close()
                closed(AgentProtocolError.malformed("frame backlog exceeded receive limit"))
                return
            }
            frameQueue.async { [weak self] in
                guard let self else { return }
                self.frameBudgetLock.lock()
                let cancelled = self.framesCancelled
                self.frameBudgetLock.unlock()
                guard !cancelled else { self.releaseFrame(bytes: cost); return }
                let result = Result { try self.framebuffer.apply(update) }
                // Make capacity available before notifying consumers that may send the next update.
                self.releaseFrame(bytes: cost)
                switch result {
                case .success(let dirty):
                    guard let rect = dirty else { return }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.isReady else { return }
                        self.onFrame?(rect)
                    }
                case .failure(let error):
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.isReady else { return }
                        if error is GuestFramebuffer.ResizeTooSoon {
                            self.repaintAfterResizeLimit()
                        } else {
                            self.onLog?("dropping frame: \(error.localizedDescription)")
                        }
                    }
                }
            }
        case .clipboard(let content):
            onClipboard?(content)
        case .ping(let n):
            send(.pong(n))
        case .pong(let n):
            lastPong = now()
            if let sent = pingSentAt.removeValue(forKey: n) { latency = lastPong - sent }
        case .log(let s):
            onLog?("guest: \(s)")
        case .appIcon(let icon):
            onAppIcon?(icon)
        case .appCatalog(let catalog):
            onAppCatalog?(catalog)
        case .guestNetwork(let info):
            guestNetwork = info
            onGuestNetwork?(info)
        case .guestStats(let stats):
            onGuestStats?(stats)
        case .cameraStatus(let status):
            onCameraStatus?(status)
        case .bluetoothStatus(let status):
            onBluetoothStatus?(status)
        case .bluetoothHCI(let packet):
            onBluetoothHCI?(packet)
        case .pointer, .key, .windowAction, .setCoherence, .fileDrop, .mountShares, .appIconRequest, .appCatalogRequest, .launchApp, .timeSync,
             .cameraStart, .cameraFrame, .cameraStop, .bluetoothStart, .bluetoothStop, .requestPermissions:
            break // host-to-guest only
        }
    }

    private func reserveFrame(bytes: Int) -> Bool {
        frameBudgetLock.lock(); defer { frameBudgetLock.unlock() }
        guard !framesCancelled, pendingFrameCount < maxPendingFrameCount,
              bytes <= maxPendingFrameBytes - pendingFrameBytes else { return false }
        pendingFrameBytes += bytes
        pendingFrameCount += 1
        return true
    }

    private func releaseFrame(bytes: Int) {
        frameBudgetLock.lock(); defer { frameBudgetLock.unlock() }
        pendingFrameBytes -= bytes
        pendingFrameCount -= 1
    }

    private func closed(_ error: Error?) {
        frameBudgetLock.lock(); framesCancelled = true; frameBudgetLock.unlock()
        pingTimer?.invalidate()
        pingTimer = nil
        if case .closed = state { return }
        state = .closed(error?.localizedDescription)
    }

    static var hostOSDescription: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
