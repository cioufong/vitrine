import Foundation

/// Request/response channel to the process that runs a VM (Vitrine.app or `vitrinectl run`): one JSON
/// object per line over `<socketDirectory>/control.sock`. It returns results, so `vitrinectl` can
/// report what happened, and it names one VM even when the owner (Vitrine.app) runs many.
public enum VMControl {
    public struct Request: Codable, Equatable, Sendable {
        /// `stop`, `suspend`, `forceStop`: start that transition and answer at once (the client waits
        /// for the run lock to be released); `suspend` is refused up front when the VM can't be
        /// suspended now (the error says why).
        /// `screenshot`, `keys`, `pointer`: drive a Virtualization.framework guest's display like a
        /// user would (QEMU guests are driven over QMP directly, see `VMAutomation`).
        /// `sample`: the mean colour of a rectangle of that display now, for timing tools
        /// (scripts/bench/display-probe.py) that poll it.
        /// `text`: type `text` through the guest agent (any characters, any keyboard layout; both
        /// backends), refused when no agent with input is connected.
        /// `requestPermissions`: have a macOS guest's agent show the prompts for Screen Recording and
        /// Accessibility, for the person at the VM's screen to answer.
        public enum Op: String, Codable, Sendable {
            case portAdd, portRemove
            case stop, suspend, forceStop
            case ping, usbList, usbAttach, usbDetach, reloadShares, dropFiles, screenshot, keys, pointer, sample, text
            case requestPermissions
        }
        public var op: Op
        public var portForward: VMConfig.PortForward?
        public var hostPort: Int?
        public var attachment: USBAttachment?
        public var id: String?
        /// Host file paths (dropFiles); `paths[0]` is the PNG to write (screenshot).
        public var paths: [String]?
        /// Key chords as QEMU qcodes, each pressed together and released (keys).
        public var chords: [[String]]?
        /// Guest display pixel (pointer, and the top-left corner for sample): x from the left, y from the top.
        public var x: Int?
        public var y: Int?
        /// sample: the rectangle's size in pixels.
        public var width: Int?
        public var height: Int?
        /// pointer: "left" or "right"; nil only moves.
        public var button: String?
        /// pointer: 1 = click, 2 = double-click.
        public var clicks: Int?
        /// text: what to type.
        public var text: String?
        public init(op: Op, attachment: USBAttachment? = nil, id: String? = nil, paths: [String]? = nil,
                    chords: [[String]]? = nil, x: Int? = nil, y: Int? = nil, width: Int? = nil, height: Int? = nil,
                    button: String? = nil, clicks: Int? = nil,
                    portForward: VMConfig.PortForward? = nil, hostPort: Int? = nil, text: String? = nil) {
            self.portForward = portForward; self.hostPort = hostPort
            self.op = op; self.attachment = attachment; self.id = id; self.paths = paths
            self.chords = chords; self.x = x; self.y = y; self.width = width; self.height = height
            self.button = button; self.clicks = clicks; self.text = text
        }
    }

    public struct Response: Codable, Equatable, Sendable {
        public var ok: Bool
        public var error: String?
        public var usb: [AttachedUSB]?
        public var attached: AttachedUSB?
        /// suspend: true when the VM can't be suspended now (`error` says why). Older Vitrine builds
        /// don't know the lifecycle ops and answer them with a plain error instead.
        public var refused: Bool?
        /// screenshot: the guest display's size in pixels.
        public var width: Int?
        public var height: Int?
        /// sample: mean red, green and blue, 0–255.
        public var color: [Double]?
        /// text: "agent" (the agent typed it) or "paste" (guest clipboard and ⌘V, for an agent that
        /// may not inject input).
        public var via: String?
        public init(ok: Bool, error: String? = nil, usb: [AttachedUSB]? = nil, attached: AttachedUSB? = nil,
                    refused: Bool? = nil, width: Int? = nil, height: Int? = nil, color: [Double]? = nil, via: String? = nil) {
            self.ok = ok; self.error = error; self.usb = usb; self.attached = attached; self.refused = refused
            self.width = width; self.height = height; self.color = color; self.via = via
        }
        public static func failure(_ error: Error) -> Response { Response(ok: false, error: error.localizedDescription) }
    }

    /// How long clients wait for a `screenshot`, `keys` or `pointer` reply. The owner stops input it
    /// can't finish by then, so nothing is typed after the client has given up.
    public static let automationTimeout: TimeInterval = 30
    /// The most key chords one `keys` request may carry: typing them takes well under
    /// `automationTimeout` (about 10 ms each).
    public static let maxKeyChords = 2000

    public static func socketURL(for bundle: VMBundle) -> URL {
        bundle.socketDirectory.appendingPathComponent("control.sock")
    }

    /// Sends one request to the VM's owner and waits for the answer.
    public static func send(_ request: Request, to bundle: VMBundle, timeout: TimeInterval = 60) throws -> Response {
        let path = socketURL(for: bundle).path
        guard let fd = try? UnixSocket.connect(path: path) else {
            throw VitrineError.io("\(bundle.name) isn't running in Vitrine or vitrinectl (no control socket)")
        }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var line = try JSONEncoder().encode(request)
        line.append(0x0A)
        guard UnixSocket.writeAll(fd, line) else { throw VitrineError.io("control socket write failed") }
        guard let reply = try readLine(fd) else { throw VitrineError.io("no answer from the VM's owner") }
        return try JSONDecoder().decode(Response.self, from: reply)
    }

    /// Reads one request or response line (at most 1 MiB); shared with the server. nil = closed
    /// before a full line.
    public static func readLine(_ fd: Int32) throws -> Data? {
        do { return try UnixSocket.readLine(fd, limit: 1 << 20) } catch let e as UnixSocket.ReadError {
            switch e {
            case .timedOut: throw VitrineError.io("the VM's owner didn't answer in time")
            case .failed: throw VitrineError.io("control socket read failed")
            case .tooLong: throw VitrineError.io("control message too long")
            }
        }
    }
}
