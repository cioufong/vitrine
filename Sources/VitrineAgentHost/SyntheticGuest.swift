import Foundation
import VitrineAgentProtocol

/// A fake guest agent speaking the real protocol over a socketpair. Used by `--coherence-demo`
/// and tests to exercise the full Coherence pipeline without a VM.
///
/// The fake display is split into four coloured quadrants (TL red, TR green, BL blue, BR yellow)
/// with a white border around each window, and two windows: one in the top-left quadrant and one
/// in the bottom-right. A moving bar in the first window animates dirty-rect updates.
public final class SyntheticGuest {
    public let hostSession: AgentSession
    private let guest: AgentChannel
    private let width: Int, height: Int, scale: Double
    private var timer: DispatchSourceTimer?
    private var tick = 0
    public private(set) var receivedInput: [AgentMessage] = []

    public init(widthPoints: Int = 1200, heightPoints: Int = 800, scale: Double = 2) {
        var fds: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        guest = AgentChannel(fileDescriptor: fds[1])
        hostSession = AgentSession(channel: AgentChannel(fileDescriptor: fds[0]))
        width = widthPoints; height = heightPoints; self.scale = scale
    }

    public var windows: [WindowInfo] {
        let w = Double(width), h = Double(height)
        return [
            WindowInfo(id: 1, pid: 1, appName: "Demo", bundleID: nil, title: "Top-left (red)",
                       frame: Rect(x: w * 0.1, y: h * 0.1, width: w * 0.3, height: h * 0.3),
                       layer: 0, kind: .normal, isFocused: true),
            WindowInfo(id: 2, pid: 1, appName: "Demo", bundleID: nil, title: "Bottom-right (yellow)",
                       frame: Rect(x: w * 0.6, y: h * 0.6, width: w * 0.3, height: h * 0.3),
                       layer: 0, kind: .normal, isFocused: false),
        ]
    }

    public func start() {
        guest.start(callbackQueue: .main, onMessage: { [weak self] m in self?.handle(m) }, onClose: { _ in })
        hostSession.start()
    }

    private func handle(_ m: AgentMessage) {
        switch m {
        case .hello:
            guest.send(.hello(Hello(role: "guest", os: "Synthetic", agentVersion: "demo",
                                    capabilities: ["coherence", "clipboard", "input"])))
            guest.send(.displayInfo(DisplayInfo(widthPoints: Double(width), heightPoints: Double(height),
                                                scale: scale, menuBarHeight: 0)))
        case .setCoherence(let req):
            if req.enabled { beginStreaming() } else { timer?.cancel(); timer = nil }
        case .ping(let n): guest.send(.pong(n))
        case .pointer, .key, .windowAction: receivedInput.append(m)
        default: break
        }
    }

    private var pw: Int { Int(Double(width) * scale) }
    private var ph: Int { Int(Double(height) * scale) }

    /// Colour of pixel (x, y) in the base pattern, BGRA little-endian as UInt32.
    func baseColor(_ x: Int, _ y: Int) -> UInt32 {
        for win in windows {
            let f = win.frame
            let x0 = Int(f.x * scale), y0 = Int(f.y * scale), x1 = Int(f.maxX * scale), y1 = Int(f.maxY * scale)
            if x >= x0 && x < x1 && y >= y0 && y < y1 && (x - x0 < 8 || x1 - x <= 8 || y - y0 < 8 || y1 - y <= 8) {
                return 0xFFFF_FFFF // white window border
            }
        }
        let left = x < pw / 2, top = y < ph / 2
        switch (left, top) {
        case (true, true): return 0xFFFF_0000   // red   (A R G B as 0xAARRGGBB → BGRA bytes)
        case (false, true): return 0xFF00_C000  // green
        case (true, false): return 0xFF00_40FF  // blue
        case (false, false): return 0xFFFF_D000 // yellow
        }
    }

    private func beginStreaming() {
        guest.send(.windowList(WindowList(windows: windows)))
        var full = Data(count: pw * ph * 4)
        full.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt32.self)
            for y in 0..<ph { for x in 0..<pw { p[y * pw + x] = baseColor(x, y) } }
        }
        guest.send(.frame(FrameUpdate(surfaceWidth: UInt32(pw), surfaceHeight: UInt32(ph), x: 0, y: 0,
                                      width: UInt32(pw), height: UInt32(ph), data: full)))
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.1, repeating: 1.0 / 30)
        t.setEventHandler { [weak self] in self?.animate() }
        t.resume()
        timer = t
    }

    /// Sweeps a black bar across the first window to exercise partial updates.
    private func animate() {
        let f = windows[0].frame
        let x0 = Int(f.x * scale) + 8, y0 = Int(f.y * scale) + 8
        let w = Int(f.width * scale) - 16, barH = 24
        let span = Int(f.height * scale) - 16 - barH
        let prevY = y0 + (tick % span)
        tick += 4
        let y = y0 + (tick % span)
        let top = min(prevY, y), bottom = max(prevY, y) + barH
        var data = Data(count: w * (bottom - top) * 4)
        data.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt32.self)
            for row in top..<bottom {
                for col in 0..<w {
                    let inBar = row >= y && row < y + barH
                    p[(row - top) * w + col] = inBar ? 0xFF10_1010 : baseColor(x0 + col, row)
                }
            }
        }
        guest.send(.frame(FrameUpdate(surfaceWidth: UInt32(pw), surfaceHeight: UInt32(ph), x: UInt32(x0), y: UInt32(top),
                                      width: UInt32(w), height: UInt32(bottom - top), data: data)))
    }
}
