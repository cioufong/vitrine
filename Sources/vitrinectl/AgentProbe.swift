import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import VitrineCore
import VitrineQEMU
import VitrineAgentHost
import VitrineAgentProtocol

/// `vitrinectl agent probe <name> [frame.png]`: end-to-end check of a running QEMU guest's agent
/// without the app — handshake, display info, Coherence capture (window list + frames, last frame
/// saved as PNG), keyboard input and two-way clipboard via a Notepad/TextEdit-style editor window
/// the caller has opened in the guest. Run the VM with VITRINE_NO_AGENT=1 so the runner doesn't
/// hold the agent's single connection.
@MainActor
enum AgentProbe {
    /// Opens an unstarted session over virtio-serial (`tcp` false) or the TCP port, nil when nothing
    /// answers. `connectQEMU` in production; tests pass a scripted guest instead.
    typealias Connect = @MainActor (VMBundle, _ tcp: Bool, _ patience: TimeInterval) -> AgentProbeSession?

    static func run(bundle: VMBundle, framePNG: URL?, editorTitle: String?, connect: Connect = connectQEMU) async throws {
        let config = try bundle.loadConfig()
        guard config.effectiveBackend == .qemu else {
            throw VitrineError.unsupported("agent probe requires a QEMU guest; use Vitrine.app to check a Virtualization.framework guest")
        }
        if let editorTitle, editorTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw VitrineError.invalidConfig("--editor needs a non-empty window title for a disposable editor document")
        }
        // virtio-serial first (current agents); then the TCP port older Windows agents listen on.
        var session: AgentProbeSession?
        // Emulated x86_64 guests answer late under load (as in the controller).
        let emulated = config.effectiveArchitecture == .x86_64
        let patience: TimeInterval = emulated ? 60 : 10
        for tcp in [false, true] {
            guard let s = connect(bundle, tcp, patience) else { continue }
            s.start()
            let deadline = Date().addingTimeInterval(patience)
            while !s.isReady, Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
            if s.isReady { session = s; break }
            s.close()
        }
        guard let session else {
            throw VitrineError.backend("could not reach the agent of \(bundle.name) (is it a running QEMU guest, run with VITRINE_NO_AGENT=1?)")
        }
        var frames = 0
        var clipboards: [String] = []
        session.onFrame = { _ in frames += 1 }
        session.onClipboard = { c in
            if let t = c.items.first(where: { $0.type == "public.utf8-plain-text" }) {
                clipboards.append(String(decoding: t.data, as: UTF8.self))
            }
        }
        session.onLog = { print("  log: \($0)") }
        var coherenceStarted = false
        defer {
            if coherenceStarted { session.setCoherence(false, maxFPS: 60) }
            session.close()
        }

        func wait(_ seconds: Double, until done: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if done() { return true }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return done()
        }
        func check(_ ok: Bool, _ what: String) throws {
            print("\(ok ? "PASS" : "FAIL")  \(what)")
            guard ok else { throw VitrineError.backend("agent probe failed: \(what)") }
        }

        let ready = await wait(10) { session.isReady }
        try check(ready, "handshake: \(session.guestHello.map { "\($0.os), agent \($0.agentVersion), caps \($0.capabilities)" } ?? "none")")
        let capabilities = session.guestHello?.capabilities ?? []
        try check(capabilities.contains("coherence"), "guest supports Coherence capture (update the agent and allow Screen Recording in a macOS guest)")
        if editorTitle != nil {
            try check(capabilities.contains("input"), "guest supports input (update the agent and allow Accessibility in a macOS guest)")
            try check(capabilities.contains("clipboard"), "guest supports clipboard (update the guest agent)")
        }
        _ = await wait(3) { session.display != nil }
        try check(session.display != nil, "display info: \(session.display.map { "\(Int($0.widthPoints))x\(Int($0.heightPoints)) @\($0.scale)x" } ?? "none")")

        coherenceStarted = true
        session.setCoherence(true, maxFPS: 30)
        _ = await wait(5) { frames > 0 && !session.windows.isEmpty }
        try check(frames > 0, "coherence capture: \(frames) frame update(s), surface \(session.framebuffer.width)x\(session.framebuffer.height)")
        try check(!session.windows.isEmpty, "window list: \(session.windows.count) window(s): " +
              session.windows.prefix(6).map { "\($0.appName) “\($0.title)”" }.joined(separator: ", "))
        if let framePNG {
            guard let surface = session.framebuffer.surface else { throw VitrineError.backend("agent probe has no captured surface to save") }
            try savePNG(surface, to: framePNG)
        }

        guard let editorTitle else { return }
        guard let editor = session.windows.first(where: { $0.title.localizedCaseInsensitiveContains(editorTitle) }) else {
            throw VitrineError.backend("agent probe failed: editor window “\(editorTitle)” not in the window list; open a disposable document matching --editor")
        }
        key(session, 0x35) // Escape: dismiss shell flyouts (Start/search) that keep keyboard focus
        try? await Task.sleep(nanoseconds: 300_000_000)
        _ = session.send(.windowAction(WindowAction(windowID: editor.id, action: .focus)))
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let focused = session.windows.first(where: { $0.id == editor.id })?.isFocused ?? false
        try check(focused, "focus window action (window list reports “\(editor.title)” focused: \(focused))")

        // Start from an empty document.
        shortcut(session, 0x00) // A
        key(session, 0x33)      // Delete (backspace)
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Guest → host: type into the editor with the agent's input path, then ⌘A ⌘C (⌘ = Ctrl on Windows).
        let marker = "vitrine-probe-\(Int.random(in: 1000...9999)) ✓"
        typeText(session, marker)
        shortcut(session, 0x00) // A
        shortcut(session, 0x08) // C
        let gotTyped = await wait(5) { clipboards.contains(marker) }
        try check(gotTyped, "keyboard input + guest→host clipboard (expected “\(marker)”, received \(clipboards.count) message(s), exact match: \(gotTyped))")

        // Host → guest: put text on the guest clipboard, paste it, add a suffix, copy it back.
        let fromHost = "from-host-\(Int.random(in: 1000...9999))"
        _ = session.send(.clipboard(ClipboardContent(items: [.init(type: "public.utf8-plain-text", data: Data(fromHost.utf8))])))
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        shortcut(session, 0x00) // A
        shortcut(session, 0x09) // V
        try? await Task.sleep(nanoseconds: 300_000_000)
        typeText(session, "!")
        shortcut(session, 0x00) // A
        shortcut(session, 0x08) // C
        let roundTrip = await wait(5) { clipboards.contains(fromHost + "!") }
        try check(roundTrip, "host→guest clipboard (expected “\(fromHost)!”, received \(clipboards.count) message(s), exact match: \(roundTrip))")
        print("      clipboard messages received from the guest: \(clipboards.count)")
        if let framePNG, let surface = session.framebuffer.surface {
            try savePNG(surface, to: framePNG.deletingPathExtension().appendingPathExtension("after.png"))
        }
    }

    static func connectQEMU(_ bundle: VMBundle, tcp: Bool, patience: TimeInterval) -> AgentProbeSession? {
        guard let channel = QEMUMachine.connectAgent(bundle: bundle, tcp: tcp) else { return nil }
        let token = tcp ? try? String(contentsOf: bundle.agentTokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) : nil
        return AgentSession(channel: channel, token: token, pongTimeout: patience)
    }

    static let commandFlag: UInt64 = 1 << 20 // NSEvent.ModifierFlags.command

    static func typeText(_ s: AgentProbeSession, _ text: String) {
        for event in KeyEvent.typing(text) ?? [] { _ = s.send(.key(event)) }
    }

    static func key(_ s: AgentProbeSession, _ code: UInt16) {
        _ = s.send(.key(KeyEvent(keyCode: code, down: true, modifiers: 0)))
        _ = s.send(.key(KeyEvent(keyCode: code, down: false, modifiers: 0)))
    }

    static func shortcut(_ s: AgentProbeSession, _ key: UInt16) {
        _ = s.send(.key(KeyEvent(keyCode: 0x37, down: true, modifiers: commandFlag)))
        _ = s.send(.key(KeyEvent(keyCode: key, down: true, modifiers: commandFlag)))
        _ = s.send(.key(KeyEvent(keyCode: key, down: false, modifiers: commandFlag)))
        _ = s.send(.key(KeyEvent(keyCode: 0x37, down: false, modifiers: 0)))
    }

    static func savePNG(_ surface: IOSurface, to url: URL) throws {
        let image = CIImage(ioSurface: surface)
        guard let cg = CIContext().createCGImage(image, from: image.extent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw VitrineError.io("agent probe could not create PNG at \(url.path)")
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw VitrineError.io("agent probe could not save PNG at \(url.path)") }
        print("      last Coherence frame saved to \(url.path)")
    }
}

/// The part of an agent connection the probe uses: `AgentSession`, or a scripted guest in tests.
protocol AgentProbeSession: AnyObject {
    var isReady: Bool { get }
    var guestHello: Hello? { get }
    var display: DisplayInfo? { get }
    var windows: [WindowInfo] { get }
    var framebuffer: GuestFramebuffer { get }
    var onFrame: ((Rect) -> Void)? { get set }
    var onClipboard: ((ClipboardContent) -> Void)? { get set }
    var onLog: ((String) -> Void)? { get set }
    func start()
    func close()
    func setCoherence(_ enabled: Bool, maxFPS: Int)
    @discardableResult func send(_ message: AgentMessage) -> Bool
}

extension AgentSession: AgentProbeSession {}
