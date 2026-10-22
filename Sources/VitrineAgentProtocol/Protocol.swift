import Foundation

/// Vitrine host ⇄ guest agent wire protocol.
///
/// Transport: a byte stream (virtio-vsock in production, a Unix socket in tests).
/// Framing:   `u32 LE length` (counts type + payload) · `u8 type` · payload.
/// Control messages carry JSON payloads; hot-path messages (frames, input) are packed binary.
public enum AgentProtocol {
    public static let version = 1
    /// vsock port the guest agent listens on.
    public static let vsockPort: UInt32 = 0x5153 // "SQ"
    /// Upper bound for one message; a full 6K BGRA frame is ~80 MB, frames are sent as dirty tiles.
    public static let maxMessageSize = 64 << 20
    /// Largest guest framebuffer edge accepted, in pixels (beyond 8K on either axis).
    public static let maxSurfaceDimension = 8192
}

public enum MessageType: UInt8, Sendable {
    case hello = 0x01
    case windowList = 0x02
    case frame = 0x03
    case displayInfo = 0x04
    case pointer = 0x10
    case key = 0x11
    case windowAction = 0x12
    case setCoherence = 0x13
    case clipboard = 0x20
    case fileDrop = 0x21
    case mountShares = 0x22
    case appIconRequest = 0x24
    case appIcon = 0x25
    case appCatalogRequest = 0x26
    case appCatalog = 0x27
    case launchApp = 0x28
    case timeSync = 0x29
    case guestNetwork = 0x2A
    case guestStats = 0x2B
    case cameraStart = 0x2C
    case cameraFrame = 0x2D
    case cameraStop = 0x2E
    case cameraStatus = 0x2F
    case ping = 0x30
    case pong = 0x31
    case bluetoothStart = 0x32
    case bluetoothHCI = 0x33
    case bluetoothStop = 0x34
    case bluetoothStatus = 0x35
    /// host → guest, no payload: ask the user in the guest for the permissions seamless mode and
    /// typing need (macOS: Screen Recording, Accessibility). Only sent to agents that offer the
    /// "permissions" capability; older agents drop the connection on unknown types.
    case requestPermissions = 0x36
    case log = 0x40
}

// MARK: - Payload types

public struct Hello: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var role: String          // "host" | "guest"
    public var os: String            // e.g. "macOS 27.0"
    public var agentVersion: String
    public var capabilities: [String] // "coherence", "clipboard", "input"
    /// Host only: the per-VM secret agents reachable over TCP require before taking the session.
    public var token: String?
    public init(protocolVersion: Int = AgentProtocol.version, role: String, os: String,
                agentVersion: String, capabilities: [String], token: String? = nil) {
        self.protocolVersion = protocolVersion; self.role = role; self.os = os
        self.agentVersion = agentVersion; self.capabilities = capabilities; self.token = token
    }
}

/// Guest display geometry. Window frames are in guest global points (top-left origin).
public struct DisplayInfo: Codable, Equatable, Sendable {
    public var widthPoints: Double
    public var heightPoints: Double
    public var scale: Double
    /// Height of the guest menu bar in points (windows never start above it).
    public var menuBarHeight: Double
    public init(widthPoints: Double, heightPoints: Double, scale: Double, menuBarHeight: Double) {
        self.widthPoints = widthPoints; self.heightPoints = heightPoints
        self.scale = scale; self.menuBarHeight = menuBarHeight
    }

    /// Positive, finite geometry within a plausible range; the guest is untrusted.
    public var isSane: Bool {
        widthPoints.isFinite && heightPoints.isFinite && scale.isFinite && menuBarHeight.isFinite
            && (1...Double(AgentProtocol.maxSurfaceDimension)).contains(widthPoints)
            && (1...Double(AgentProtocol.maxSurfaceDimension)).contains(heightPoints)
            && (0.5...8).contains(scale) && (0..<heightPoints).contains(menuBarHeight)
    }
}

public struct Rect: Codable, Equatable, Hashable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    /// Finite and within a generous coordinate range; the guest is untrusted.
    public var isSane: Bool {
        [x, y, width, height].allSatisfy { $0.isFinite && abs($0) <= 100_000 } && width >= 0 && height >= 0
    }
    public func intersection(_ o: Rect) -> Rect {
        let nx = max(x, o.x), ny = max(y, o.y)
        let w = min(maxX, o.maxX) - nx, h = min(maxY, o.maxY) - ny
        return w > 0 && h > 0 ? Rect(x: nx, y: ny, width: w, height: h) : Rect(x: 0, y: 0, width: 0, height: 0)
    }
    public func union(_ o: Rect) -> Rect {
        if isEmpty { return o }
        if o.isEmpty { return self }
        let nx = min(x, o.x), ny = min(y, o.y)
        return Rect(x: nx, y: ny, width: max(maxX, o.maxX) - nx, height: max(maxY, o.maxY) - ny)
    }
}

public struct WindowInfo: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case normal      // titled app window
        case panel       // utility/floating panel
        case menu        // pop-up/context menu, tooltip, transient overlay
        case menuBar     // guest system menu bar
    }
    public var id: UInt32
    public var pid: Int32
    public var appName: String
    public var bundleID: String?
    public var title: String
    /// Guest global coordinates in points, top-left origin.
    public var frame: Rect
    public var layer: Int
    public var kind: Kind
    public var isFocused: Bool
    public init(id: UInt32, pid: Int32, appName: String, bundleID: String?, title: String, frame: Rect,
                layer: Int, kind: Kind, isFocused: Bool) {
        self.id = id; self.pid = pid; self.appName = appName; self.bundleID = bundleID; self.title = title
        self.frame = frame; self.layer = layer; self.kind = kind; self.isFocused = isFocused
    }
}

/// Windows ordered front-to-back.
public struct WindowList: Codable, Equatable, Sendable {
    public var windows: [WindowInfo]
    public init(windows: [WindowInfo]) { self.windows = windows }
}

/// Dirty rectangle of the guest display framebuffer. Pixels are BGRA8 premultiplied.
public struct FrameUpdate: Equatable, Sendable {
    public enum Encoding: UInt8, Sendable { case raw = 0, lz4 = 1 }
    /// Full framebuffer size in pixels. A change means the host must reallocate.
    public var surfaceWidth: UInt32
    public var surfaceHeight: UInt32
    /// Dirty region in pixels.
    public var x: UInt32, y: UInt32, width: UInt32, height: UInt32
    public var encoding: Encoding
    /// Tightly packed rows (stride = width * 4) once decoded.
    public var data: Data
    public init(surfaceWidth: UInt32, surfaceHeight: UInt32, x: UInt32, y: UInt32, width: UInt32, height: UInt32,
                encoding: Encoding = .raw, data: Data) {
        self.surfaceWidth = surfaceWidth; self.surfaceHeight = surfaceHeight
        self.x = x; self.y = y; self.width = width; self.height = height
        self.encoding = encoding; self.data = data
    }
    public var decodedByteCount: Int { Int(width) * Int(height) * 4 }
}

public struct PointerEvent: Equatable, Sendable {
    public enum Kind: UInt8, Sendable { case move = 0, down = 1, up = 2, drag = 3, scroll = 4 }
    public enum Button: UInt8, Sendable { case left = 0, right = 1, other = 2 }
    public var kind: Kind
    public var button: Button
    public var clickCount: UInt8
    /// Guest global coordinates in points.
    public var x: Float, y: Float
    public var scrollDX: Float, scrollDY: Float
    /// CGEventFlags raw value.
    public var modifiers: UInt64
    /// Whether scroll deltas are precise (trackpad) pixel deltas.
    public var preciseScroll: Bool
    public init(kind: Kind, button: Button = .left, clickCount: UInt8 = 1, x: Float, y: Float,
                scrollDX: Float = 0, scrollDY: Float = 0, modifiers: UInt64 = 0, preciseScroll: Bool = false) {
        self.kind = kind; self.button = button; self.clickCount = clickCount; self.x = x; self.y = y
        self.scrollDX = scrollDX; self.scrollDY = scrollDY; self.modifiers = modifiers; self.preciseScroll = preciseScroll
    }
}

public struct KeyEvent: Equatable, Sendable {
    /// macOS virtual key code (kVK_*). Identical on host and macOS guest.
    public var keyCode: UInt16
    public var down: Bool
    public var modifiers: UInt64
    /// Characters the host produced for this key (may be empty). Injected alongside the key code so
    /// synthesized input (emoji picker, text expanders, automation) arrives with the right text.
    public var text: String
    public init(keyCode: UInt16, down: Bool, modifiers: UInt64, text: String = "") {
        self.keyCode = keyCode; self.down = down; self.modifiers = modifiers; self.text = text
    }

    /// Key code for events that carry only text; every agent types their `text` as is.
    public static let textOnly: UInt16 = 0xFFFF

    /// Key presses (down, up) that make an agent type `text` exactly, whatever the guest's keyboard
    /// layout: each character as text-only events, except newline and tab, which are sent as the
    /// Return and Tab keys (agents don't type control characters from text). Nil when `text`
    /// holds another control character.
    public static func typing(_ text: String) -> [KeyEvent]? {
        var events: [KeyEvent] = []
        for ch in text {
            let code: UInt16, chars: String
            switch ch {
            case "\n", "\r", "\r\n": (code, chars) = (0x24, "\r") // kVK_Return
            case "\t": (code, chars) = (0x30, "\t")               // kVK_Tab
            default:
                guard !ch.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
                (code, chars) = (textOnly, String(ch))
            }
            events.append(KeyEvent(keyCode: code, down: true, modifiers: 0, text: chars))
            events.append(KeyEvent(keyCode: code, down: false, modifiers: 0, text: chars))
        }
        return events
    }
}

public struct WindowAction: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case focus, close, minimize, move, resize, zoom }
    public var windowID: UInt32
    public var action: Action
    /// Target frame for move/resize, guest points.
    public var frame: Rect?
    public init(windowID: UInt32, action: Action, frame: Rect? = nil) {
        self.windowID = windowID; self.action = action; self.frame = frame
    }
}

public struct CoherenceRequest: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var maxFPS: Int
    public init(enabled: Bool, maxFPS: Int = 60) { self.enabled = enabled; self.maxFPS = maxFPS }
}

public struct ClipboardContent: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        /// UTI, e.g. "public.utf8-plain-text", "public.rtf", "public.png", "public.html".
        public var type: String
        public var data: Data
        public init(type: String, data: Data) { self.type = type; self.data = data }
    }
    public var items: [Item]
    public init(items: [Item]) { self.items = items }

    /// Order-independent fingerprint used to suppress echo loops between host and guest.
    public var fingerprint: Int {
        var h = Hasher()
        for item in items.sorted(by: { $0.type < $1.type }) { h.combine(item.type); h.combine(item.data) }
        return h.finalize()
    }
}

/// Files the host placed in the "Vitrine Transfer" shared folder for the guest to take
/// (drag and drop from the Mac). Paths are relative to that folder.
public struct FileDrop: Codable, Equatable, Sendable {
    public var files: [String]
    /// Guest point (points) where the files were dropped, if dropped onto a Coherence window.
    public var x: Double?
    public var y: Double?
    public init(files: [String], x: Double? = nil, y: Double? = nil) { self.files = files; self.x = x; self.y = y }
}

/// Network shares the guest should map (Windows: SMB served by the host through QEMU's user-mode
/// network). The password is per VM run and only valid for that run's SMB server.
public struct MountShares: Codable, Equatable, Sendable {
    public struct Share: Codable, Equatable, Sendable {
        /// SMB share name (also the drive label shown in the guest).
        public var name: String
        /// Drive letter to map, e.g. "Z"; nil = reachable by UNC path only.
        public var letter: String?
        public var readOnly: Bool
        public init(name: String, letter: String?, readOnly: Bool) {
            self.name = name; self.letter = letter; self.readOnly = readOnly
        }
    }
    public var server: String
    public var username: String
    public var password: String
    public var shares: [Share]
    public init(server: String, username: String, password: String, shares: [Share]) {
        self.server = server; self.username = username; self.password = password; self.shares = shares
    }
}

/// Host asks for the icon of a guest app, identified by `WindowInfo.appKey`.
public struct AppIconRequest: Codable, Equatable, Sendable {
    public var key: String
    public init(key: String) { self.key = key }
}

/// A guest app's icon as PNG (empty when the guest has none).
public struct AppIcon: Codable, Equatable, Sendable {
    public var key: String
    public var png: Data
    public init(key: String, png: Data) { self.key = key; self.png = png }
}

/// Host asks for the guest's launchable apps.
public struct AppCatalogRequest: Codable, Equatable, Sendable {
    /// Edge length of the icons to include, in pixels (0 = no icons).
    public var iconSize: Int
    public init(iconSize: Int = 128) { self.iconSize = iconSize }
}

/// Apps the guest can launch (Applications folder, .desktop files, Start menu).
public struct AppCatalog: Codable, Equatable, Sendable {
    public struct App: Codable, Equatable, Sendable {
        /// Opaque to the host; passed back in `LaunchApp`.
        public var id: String
        public var name: String
        /// The `WindowInfo.appKey` its windows will have, when the guest can tell.
        public var key: String?
        public var png: Data?
        public init(id: String, name: String, key: String? = nil, png: Data? = nil) {
            self.id = id; self.name = name; self.key = key; self.png = png
        }
    }
    public var apps: [App]
    public init(apps: [App]) { self.apps = apps }
}

/// Starts (or activates) a guest app from `AppCatalog`.
public struct LaunchApp: Codable, Equatable, Sendable {
    public var id: String
    public init(id: String) { self.id = id }
}

/// The host's clock, sent when the agent connects (e.g. after a resume, when the guest clock lags
/// by however long the VM was suspended). Agents that may change the clock adopt it.
public struct TimeSync: Codable, Equatable, Sendable {
    /// Milliseconds since 1970-01-01 UTC.
    public var unixMillis: Int64
    /// The Mac's time zone, IANA ("Asia/Taipei") and Windows ("Taipei Standard Time") forms.
    public var timeZone: String?
    public var windowsTimeZone: String?
    public init(unixMillis: Int64, timeZone: String? = nil, windowsTimeZone: String? = nil) {
        self.unixMillis = unixMillis; self.timeZone = timeZone; self.windowsTimeZone = windowsTimeZone
    }
}

/// Host → guest: the Mac's camera is being shared; expect `cameraFrame`s of this size. Sent only to
/// agents whose Hello lists "camera".
public struct CameraStart: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public init(width: Int, height: Int, fps: Int) { self.width = width; self.height = height; self.fps = fps }
}

/// Host → guest: one camera image, packed YUYV 4:2:2 (`width × height × 2` bytes).
public struct CameraFrame: Equatable, Sendable {
    public static let maxDimension: UInt32 = 4096
    public var width: UInt32
    public var height: UInt32
    public var data: Data
    public init(width: UInt32, height: UInt32, data: Data) { self.width = width; self.height = height; self.data = data }
}

/// Guest → host, in answer to `cameraStart` or `bluetoothStart` (and when the guest's Bluetooth
/// controller goes away): whether the guest took the shared device. Camera and Bluetooth status
/// are the same JSON, sent as their own message types.
public struct ShareStatus: Codable, Equatable, Sendable {
    public var ready: Bool
    /// The guest device, e.g. "/dev/video0" (the camera's frames go there) or "hci0".
    public var device: String?
    /// Why it isn't ready, e.g. "v4l2loopback is not loaded".
    public var error: String?
    /// Whether the host's "install camera support" ("install Bluetooth support") would fix it;
    /// nil (older agents) means yes.
    public var installable: Bool?
    public init(ready: Bool, device: String? = nil, error: String? = nil, installable: Bool? = nil) {
        self.ready = ready; self.device = device; self.error = error; self.installable = installable
    }
}

/// Guest → host, in answer to `cameraStart`: whether the guest's virtual camera took the stream.
public typealias CameraStatus = ShareStatus

/// Bluetooth for guests: the host emulates a Bluetooth LE controller backed by the Mac's Bluetooth
/// (CoreBluetooth) and the agent attaches it to the guest's Bluetooth stack. `bluetoothStart` and
/// `bluetoothStop` carry no payload; they're sent only to agents whose Hello lists "bluetooth".
/// `bluetoothHCI` is one HCI packet, both directions, in UART (H4) framing: a packet-type byte
/// (1 command, 2 ACL data, 4 event) followed by the packet.
public enum BluetoothHCI {
    public static let maxSize = 4096
}

/// Guest → host, in answer to `bluetoothStart` (and when the guest's controller goes away); the
/// device is the guest's controller, e.g. "hci0".
public typealias BluetoothStatus = ShareStatus

/// How busy the guest is, sent every few seconds when the host's Hello lists "stats". Shown in the
/// VM window's status bar. Byte counts; nil where the guest can't tell.
public struct GuestStats: Codable, Equatable, Sendable {
    /// All CPUs together, 0–100, over the last interval.
    public var cpuPercent: Double?
    public var memoryUsed: UInt64?
    public var memoryTotal: UInt64?
    /// The volume holding the system.
    public var diskUsed: UInt64?
    public var diskTotal: UInt64?
    public var uptimeSeconds: UInt64?
    /// "Debian GNU/Linux 13 (trixie)", "macOS 26.1", "Windows 11 Pro 24H2".
    public var osName: String?
    public init(cpuPercent: Double? = nil, memoryUsed: UInt64? = nil, memoryTotal: UInt64? = nil,
                diskUsed: UInt64? = nil, diskTotal: UInt64? = nil, uptimeSeconds: UInt64? = nil, osName: String? = nil) {
        self.cpuPercent = cpuPercent; self.memoryUsed = memoryUsed; self.memoryTotal = memoryTotal
        self.diskUsed = diskUsed; self.diskTotal = diskTotal; self.uptimeSeconds = uptimeSeconds; self.osName = osName
    }

    /// The guest is untrusted: plausible numbers and a short name.
    public var isSane: Bool {
        (cpuPercent.map { $0.isFinite && $0 >= 0 && $0 <= 100.5 } ?? true)
            && (osName?.utf8.count ?? 0) <= 128
            && (memoryUsed ?? 0) <= (memoryTotal ?? .max) && (diskUsed ?? 0) <= (diskTotal ?? .max)
    }
}

/// The guest's network interfaces and addresses, sent by agents when the host's Hello lists
/// "network" and again when they change. The host uses it to reach guests whose address isn't in
/// the Mac's DHCP leases (vmnet networks, bridged networks).
public struct GuestNetworkInfo: Codable, Equatable, Sendable {
    public struct Interface: Codable, Equatable, Sendable {
        public var name: String
        /// Lowercase, colon-separated.
        public var mac: String
        public var ipv4: [String]
        public var ipv6: [String]
        public init(name: String, mac: String, ipv4: [String], ipv6: [String] = []) {
            self.name = name; self.mac = mac; self.ipv4 = ipv4; self.ipv6 = ipv6
        }
    }
    public var interfaces: [Interface]
    public init(interfaces: [Interface]) { self.interfaces = interfaces }

    /// The guest is untrusted: a handful of interfaces with short strings.
    public var isSane: Bool {
        interfaces.count <= 64 && interfaces.allSatisfy { i in
            i.name.utf8.count <= 64 && i.mac.utf8.count <= 32 && i.ipv4.count <= 32 && i.ipv6.count <= 32
                && (i.ipv4 + i.ipv6).allSatisfy { $0.utf8.count <= 64 }
        }
    }

    /// IPv4 addresses of the interface with `mac` (any MAC notation), else nil.
    public func ipv4(forMAC mac: String) -> [String]? {
        let want = Self.normalize(mac)
        return interfaces.first { Self.normalize($0.mac) == want }?.ipv4
    }

    static func normalize(_ mac: String) -> String {
        mac.lowercased().replacingOccurrences(of: "-", with: ":").split(separator: ":")
            .map { String(UInt8($0, radix: 16) ?? 0, radix: 16) }.joined(separator: ":")
    }
}

public extension WindowInfo {
    /// Groups windows by app: bundle identifier (macOS), executable path (Windows) or WM_CLASS
    /// (Linux), else the app name.
    var appKey: String { bundleID ?? appName }
}

/// Name of the per-VM shared folder used for drag-and-drop transfers.
public let transferShareName = "Vitrine Transfer"

// MARK: - Message

public enum AgentMessage: Equatable, Sendable {
    case hello(Hello)
    case windowList(WindowList)
    case frame(FrameUpdate)
    case displayInfo(DisplayInfo)
    case pointer(PointerEvent)
    case key(KeyEvent)
    case windowAction(WindowAction)
    case setCoherence(CoherenceRequest)
    case clipboard(ClipboardContent)
    case fileDrop(FileDrop)
    case mountShares(MountShares)
    case appIconRequest(AppIconRequest)
    case appIcon(AppIcon)
    case appCatalogRequest(AppCatalogRequest)
    case appCatalog(AppCatalog)
    case launchApp(LaunchApp)
    case timeSync(TimeSync)
    case guestNetwork(GuestNetworkInfo)
    case guestStats(GuestStats)
    case cameraStart(CameraStart)
    case cameraFrame(CameraFrame)
    case cameraStop
    case cameraStatus(CameraStatus)
    case bluetoothStart
    case bluetoothHCI(Data)
    case bluetoothStop
    case bluetoothStatus(BluetoothStatus)
    case requestPermissions
    case ping(UInt64)
    case pong(UInt64)
    case log(String)

    public var type: MessageType {
        switch self {
        case .hello: return .hello
        case .windowList: return .windowList
        case .frame: return .frame
        case .displayInfo: return .displayInfo
        case .pointer: return .pointer
        case .key: return .key
        case .windowAction: return .windowAction
        case .setCoherence: return .setCoherence
        case .clipboard: return .clipboard
        case .fileDrop: return .fileDrop
        case .mountShares: return .mountShares
        case .appIconRequest: return .appIconRequest
        case .appIcon: return .appIcon
        case .appCatalogRequest: return .appCatalogRequest
        case .appCatalog: return .appCatalog
        case .launchApp: return .launchApp
        case .timeSync: return .timeSync
        case .guestNetwork: return .guestNetwork
        case .guestStats: return .guestStats
        case .cameraStart: return .cameraStart
        case .cameraFrame: return .cameraFrame
        case .cameraStop: return .cameraStop
        case .cameraStatus: return .cameraStatus
        case .bluetoothStart: return .bluetoothStart
        case .bluetoothHCI: return .bluetoothHCI
        case .bluetoothStop: return .bluetoothStop
        case .bluetoothStatus: return .bluetoothStatus
        case .requestPermissions: return .requestPermissions
        case .ping: return .ping
        case .pong: return .pong
        case .log: return .log
        }
    }

    /// Rough in-memory size, used for receive-side back-pressure.
    public var approximateSize: Int {
        switch self {
        case .frame(let f): return f.data.count + 64
        case .cameraFrame(let f): return f.data.count + 64
        case .clipboard(let c): return c.items.reduce(64) { $0 + $1.data.count + $1.type.utf8.count }
        case .windowList(let l):
            return l.windows.reduce(64) { $0 + 256 + $1.title.utf8.count + $1.appName.utf8.count + ($1.bundleID?.utf8.count ?? 0) }
        case .log(let s): return 64 + s.utf8.count
        // Every guest-supplied string counts: a catalog of one app with a huge name is still huge.
        case .appIcon(let i): return 64 + i.png.count + i.key.utf8.count
        case .appCatalog(let c):
            return c.apps.reduce(64) {
                $0 + 128 + ($1.png?.count ?? 0) + $1.id.utf8.count + $1.name.utf8.count + ($1.key?.utf8.count ?? 0)
            }
        default: return 256
        }
    }
}

// MARK: - Codec

public enum AgentCodec {
    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = .sortedKeys; return e }()
    static let decoder = JSONDecoder()

    /// Serializes a message including its length prefix.
    public static func encode(_ message: AgentMessage) throws -> Data {
        var payload = Data()
        switch message {
        case .hello(let v): payload = try encoder.encode(v)
        case .windowList(let v): payload = try encoder.encode(v)
        case .displayInfo(let v): payload = try encoder.encode(v)
        case .windowAction(let v): payload = try encoder.encode(v)
        case .setCoherence(let v): payload = try encoder.encode(v)
        case .clipboard(let v): payload = try encoder.encode(v)
        case .fileDrop(let v): payload = try encoder.encode(v)
        case .mountShares(let v): payload = try encoder.encode(v)
        case .appIconRequest(let v): payload = try encoder.encode(v)
        case .appIcon(let v): payload = try encoder.encode(v)
        case .appCatalogRequest(let v): payload = try encoder.encode(v)
        case .appCatalog(let v): payload = try encoder.encode(v)
        case .launchApp(let v): payload = try encoder.encode(v)
        case .timeSync(let v): payload = try encoder.encode(v)
        case .guestNetwork(let v): payload = try encoder.encode(v)
        case .guestStats(let v): payload = try encoder.encode(v)
        case .cameraStart(let v): payload = try encoder.encode(v)
        case .cameraStatus(let v): payload = try encoder.encode(v)
        case .cameraStop, .bluetoothStart, .bluetoothStop, .requestPermissions: break
        case .bluetoothStatus(let v): payload = try encoder.encode(v)
        case .bluetoothHCI(let packet): payload = packet
        case .cameraFrame(let f):
            payload.reserveCapacity(8 + f.data.count)
            payload.appendLE(f.width); payload.appendLE(f.height)
            payload.append(f.data)
        case .log(let s): payload = Data(s.utf8)
        case .ping(let n), .pong(let n): payload.appendLE(n)
        case .frame(let f):
            payload.reserveCapacity(25 + f.data.count)
            payload.appendLE(f.surfaceWidth); payload.appendLE(f.surfaceHeight)
            payload.appendLE(f.x); payload.appendLE(f.y); payload.appendLE(f.width); payload.appendLE(f.height)
            payload.append(f.encoding.rawValue)
            payload.append(f.data)
        case .pointer(let p):
            payload.append(p.kind.rawValue); payload.append(p.button.rawValue); payload.append(p.clickCount)
            payload.append(p.preciseScroll ? 1 : 0)
            payload.appendLE(p.x.bitPattern); payload.appendLE(p.y.bitPattern)
            payload.appendLE(p.scrollDX.bitPattern); payload.appendLE(p.scrollDY.bitPattern)
            payload.appendLE(p.modifiers)
        case .key(let k):
            payload.appendLE(k.keyCode); payload.append(k.down ? 1 : 0); payload.appendLE(k.modifiers)
            payload.append(Data(k.text.utf8))
        }
        let length = payload.count + 1
        guard length <= AgentProtocol.maxMessageSize else {
            throw AgentProtocolError.messageTooLarge(length)
        }
        var out = Data(capacity: 4 + length)
        out.appendLE(UInt32(length))
        out.append(message.type.rawValue)
        out.append(payload)
        return out
    }

    /// Decodes a message body (type byte + payload, without the length prefix).
    public static func decode(type rawType: UInt8, payload: Data) throws -> AgentMessage {
        guard let type = MessageType(rawValue: rawType) else { throw AgentProtocolError.unknownType(rawType) }
        var r = ByteReader(payload)
        switch type {
        case .hello: return .hello(try decoder.decode(Hello.self, from: payload))
        case .windowList: return .windowList(try decoder.decode(WindowList.self, from: payload))
        case .displayInfo: return .displayInfo(try decoder.decode(DisplayInfo.self, from: payload))
        case .windowAction: return .windowAction(try decoder.decode(WindowAction.self, from: payload))
        case .setCoherence: return .setCoherence(try decoder.decode(CoherenceRequest.self, from: payload))
        case .clipboard: return .clipboard(try decoder.decode(ClipboardContent.self, from: payload))
        case .fileDrop: return .fileDrop(try decoder.decode(FileDrop.self, from: payload))
        case .mountShares: return .mountShares(try decoder.decode(MountShares.self, from: payload))
        case .appIconRequest: return .appIconRequest(try decoder.decode(AppIconRequest.self, from: payload))
        case .appIcon: return .appIcon(try decoder.decode(AppIcon.self, from: payload))
        case .appCatalogRequest: return .appCatalogRequest(try decoder.decode(AppCatalogRequest.self, from: payload))
        case .appCatalog: return .appCatalog(try decoder.decode(AppCatalog.self, from: payload))
        case .launchApp: return .launchApp(try decoder.decode(LaunchApp.self, from: payload))
        case .timeSync: return .timeSync(try decoder.decode(TimeSync.self, from: payload))
        case .guestNetwork:
            let info = try decoder.decode(GuestNetworkInfo.self, from: payload)
            guard info.isSane else { throw AgentProtocolError.malformed("guest network info") }
            return .guestNetwork(info)
        case .guestStats:
            let stats = try decoder.decode(GuestStats.self, from: payload)
            guard stats.isSane else { throw AgentProtocolError.malformed("guest stats") }
            return .guestStats(stats)
        case .cameraStart:
            let v = try decoder.decode(CameraStart.self, from: payload)
            guard (1...Int(CameraFrame.maxDimension)).contains(v.width), (1...Int(CameraFrame.maxDimension)).contains(v.height),
                  (1...120).contains(v.fps) else { throw AgentProtocolError.malformed("camera size") }
            return .cameraStart(v)
        case .cameraFrame:
            let w = try r.u32(), h = try r.u32()
            let data = r.rest()
            guard w > 0, h > 0, w <= CameraFrame.maxDimension, h <= CameraFrame.maxDimension,
                  data.count == Int(w) * Int(h) * 2 else { throw AgentProtocolError.malformed("camera frame") }
            return .cameraFrame(CameraFrame(width: w, height: h, data: data))
        case .cameraStop: return .cameraStop
        case .requestPermissions: return .requestPermissions
        case .cameraStatus:
            let v = try decoder.decode(CameraStatus.self, from: payload)
            guard (v.device?.utf8.count ?? 0) <= 256, (v.error?.utf8.count ?? 0) <= 1024 else {
                throw AgentProtocolError.malformed("camera status")
            }
            return .cameraStatus(v)
        case .bluetoothStart: return .bluetoothStart
        case .bluetoothStop: return .bluetoothStop
        case .bluetoothHCI:
            guard (2...BluetoothHCI.maxSize).contains(payload.count) else { throw AgentProtocolError.malformed("HCI packet") }
            return .bluetoothHCI(Data(payload))
        case .bluetoothStatus:
            let v = try decoder.decode(BluetoothStatus.self, from: payload)
            guard (v.device?.utf8.count ?? 0) <= 256, (v.error?.utf8.count ?? 0) <= 1024 else {
                throw AgentProtocolError.malformed("Bluetooth status")
            }
            return .bluetoothStatus(v)
        case .log: return .log(String(decoding: payload, as: UTF8.self))
        case .ping: return .ping(try r.u64())
        case .pong: return .pong(try r.u64())
        case .frame:
            let sw = try r.u32(), sh = try r.u32(), x = try r.u32(), y = try r.u32(), w = try r.u32(), h = try r.u32()
            guard let enc = FrameUpdate.Encoding(rawValue: try r.u8()) else { throw AgentProtocolError.malformed("frame encoding") }
            let data = r.rest()
            // The guest is untrusted: bound sizes before any arithmetic so nothing can overflow.
            let limit = UInt32(AgentProtocol.maxSurfaceDimension)
            guard sw > 0, sh > 0, sw <= limit, sh <= limit else { throw AgentProtocolError.malformed("surface size \(sw)x\(sh)") }
            guard UInt64(x) + UInt64(w) <= UInt64(sw), UInt64(y) + UInt64(h) <= UInt64(sh) else {
                throw AgentProtocolError.malformed("frame rect outside surface")
            }
            if enc == .raw && data.count != Int(w) * Int(h) * 4 {
                throw AgentProtocolError.malformed("raw frame size \(data.count) != \(w)x\(h)x4")
            }
            return .frame(FrameUpdate(surfaceWidth: sw, surfaceHeight: sh, x: x, y: y, width: w, height: h,
                                      encoding: enc, data: data))
        case .pointer:
            guard let kind = PointerEvent.Kind(rawValue: try r.u8()),
                  let button = PointerEvent.Button(rawValue: try r.u8()) else { throw AgentProtocolError.malformed("pointer") }
            let clicks = try r.u8(); let precise = try r.u8() != 0
            let x = Float(bitPattern: try r.u32()), y = Float(bitPattern: try r.u32())
            let dx = Float(bitPattern: try r.u32()), dy = Float(bitPattern: try r.u32())
            let mods = try r.u64()
            return .pointer(PointerEvent(kind: kind, button: button, clickCount: clicks, x: x, y: y,
                                         scrollDX: dx, scrollDY: dy, modifiers: mods, preciseScroll: precise))
        case .key:
            let code = try r.u16(); let down = try r.u8() != 0; let mods = try r.u64()
            let text = String(decoding: r.rest(), as: UTF8.self)
            return .key(KeyEvent(keyCode: code, down: down, modifiers: mods, text: text))
        }
    }
}

public enum AgentProtocolError: Error, Equatable, LocalizedError {
    case unknownType(UInt8)
    case malformed(String)
    case messageTooLarge(Int)
    case truncated

    public var errorDescription: String? {
        switch self {
        case .unknownType(let t): return "unknown agent message type 0x\(String(t, radix: 16))"
        case .malformed(let m): return "malformed agent message: \(m)"
        case .messageTooLarge(let n): return "agent message too large (\(n) bytes)"
        case .truncated: return "truncated agent message"
        }
    }
}

/// Incremental stream deframer: feed bytes as they arrive, pull complete messages out.
public struct MessageDeframer {
    private var buffer = Data()
    public init() {}

    public mutating func append(_ data: Data) { buffer.append(data) }

    /// Wire size (length prefix included) of the message `next()` returned last.
    public private(set) var lastMessageSize = 0

    /// Returns the next complete message, nil if more bytes are needed.
    public mutating func next() throws -> AgentMessage? {
        guard buffer.count >= 5 else { return nil }
        let start = buffer.startIndex
        let length = Int(UInt32(buffer[start]) | UInt32(buffer[start + 1]) << 8
                         | UInt32(buffer[start + 2]) << 16 | UInt32(buffer[start + 3]) << 24)
        guard length >= 1 else { throw AgentProtocolError.malformed("zero-length message") }
        guard length <= AgentProtocol.maxMessageSize else { throw AgentProtocolError.messageTooLarge(length) }
        guard buffer.count >= 4 + length else { return nil }
        let type = buffer[start + 4]
        let payload = Data(buffer[(start + 5)..<(start + 4 + length)])
        buffer.removeSubrange(start..<(start + 4 + length))
        lastMessageSize = 4 + length
        return try AgentCodec.decode(type: type, payload: payload)
    }

    public var bufferedByteCount: Int { buffer.count }
}

// MARK: - Byte helpers

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
}

struct ByteReader {
    private let data: Data
    private var offset: Int
    init(_ data: Data) { self.data = data; self.offset = data.startIndex }

    mutating func read<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.endIndex else { throw AgentProtocolError.truncated }
        var v: T = 0
        for i in 0..<size { v |= T(data[offset + i]) << (8 * i) }
        offset += size
        return v
    }
    mutating func u8() throws -> UInt8 { try read(UInt8.self) }
    mutating func u16() throws -> UInt16 { try read(UInt16.self) }
    mutating func u32() throws -> UInt32 { try read(UInt32.self) }
    mutating func u64() throws -> UInt64 { try read(UInt64.self) }
    mutating func rest() -> Data { let d = Data(data[offset...]); offset = data.endIndex; return d }
}
