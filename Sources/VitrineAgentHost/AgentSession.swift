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

    public static let hostAgentVersion = "0.1.0"

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
    private var lastPong = Date()
    private var pingNonce: UInt64 = 0
    /// Round-trip latency of the last ping, for diagnostics.
    public private(set) var latency: TimeInterval?
    private var pingSentAt: [UInt64: Date] = [:]

    private let token: String?

    /// `token`: the VM's agent secret, for agents reached over TCP (they ignore a missing one only
    /// when the VM wasn't started with it).
    /// How long the guest may go without answering pings before the session is given up.
    private let pongTimeout: TimeInterval

    /// `pongTimeout`: 10 s suits hardware-accelerated guests; fully emulated ones (x86_64 on Apple
    /// silicon) can stall far longer under load without anything being wrong.
    public convenience init(channel: AgentChannel, token: String? = nil, pongTimeout: TimeInterval = 10) {
        self.init(channel: channel, token: token, pongTimeout: pongTimeout,
                  frameQueue: DispatchQueue(label: "vitrine.agent.frames", qos: .userInteractive),
                  maxPendingFrameBytes: 128 << 20, maxPendingFrameCount: 1024)
    }

    init(channel: AgentChannel, token: String? = nil, pongTimeout: TimeInterval = 10,
         frameQueue: DispatchQueue, maxPendingFrameBytes: Int, maxPendingFrameCount: Int) {
        precondition(maxPendingFrameBytes > 0 && maxPendingFrameCount > 0)
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
        lastPong = Date()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.keepalive() }
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
        send(.setCoherence(CoherenceRequest(enabled: enabled, maxFPS: maxFPS)))
    }

    private func keepalive() {
        if Date().timeIntervalSince(lastPong) > pongTimeout {
            // A virtio-serial chardev accepts connections even when no agent runs in the guest, so a
            // session that never said hello is just "no agent yet" — close quietly and let the caller retry.
            if isReady { onLog?("guest agent stopped responding") }
            close()
            return
        }
        pingNonce &+= 1
        pingSentAt[pingNonce] = Date()
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
            lastPong = Date()
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
                        self.onLog?("dropping frame: \(error.localizedDescription)")
                    }
                }
            }
        case .clipboard(let content):
            onClipboard?(content)
        case .ping(let n):
            send(.pong(n))
        case .pong(let n):
            lastPong = Date()
            if let sent = pingSentAt.removeValue(forKey: n) { latency = Date().timeIntervalSince(sent) }
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
