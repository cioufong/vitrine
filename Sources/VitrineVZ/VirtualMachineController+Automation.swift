import AppKit
import Virtualization
import VitrineCore
import VitrineAgentProtocol
import VitrineAgentHost

/// Screenshots, typing and clicks for Virtualization.framework guests, requested over the control
/// socket (`vitrinectl screenshot|keys|click`, the MCP server). Input goes through the display view
/// as virtual USB keyboard and pointer events, so it works without a guest agent: at login screens,
/// in installers and in guests that never granted Accessibility access.
extension VirtualMachineController {
    func handleAutomation(_ request: VMControl.Request) async throws -> VMControl.Response {
        // The client gives up after `automationTimeout`; finish (or refuse) input before then.
        let deadline = Date().addingTimeInterval(VMControl.automationTimeout - 2)
        guard state == .running else { throw VitrineError.invalidConfig("\(bundle.name) isn't running") }
        guard qemu == nil else {
            throw VitrineError.unsupported("QEMU guests are driven over QMP (vitrinectl talks to QEMU directly)")
        }
        switch request.op {
        case .screenshot:
            let view = try automationView()
            guard let path = request.paths?.first else { throw VitrineError.invalidConfig("no output path") }
            // A display that has just been presented needs a moment for its first frame.
            for attempt in 0..<30 {
                do {
                    let size = try view.screenshot(to: URL(fileURLWithPath: path))
                    return VMControl.Response(ok: true, width: Int(size.width), height: Int(size.height))
                } catch where attempt < 29 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            throw VitrineError.unsupported("the guest display has no frame yet")
        case .sample:
            guard let x = request.x, let y = request.y, let w = request.width, let h = request.height, w > 0, h > 0 else {
                throw VitrineError.invalidConfig("sample needs x, y, width and height")
            }
            return VMControl.Response(ok: true, color: try automationView().meanColor(in: CGRect(x: x, y: y, width: w, height: h)))
        case .keys:
            let chords = request.chords ?? []
            guard chords.count <= VMControl.maxKeyChords else {
                throw VitrineError.invalidConfig("\(chords.count) keys are more than \(VMControl.maxKeyChords) at once; send them in parts")
            }
            // The view is looked up once it's this request's turn: the queue wait may have replaced it.
            let run = virtualMachine
            try await automationInput.run(until: deadline) { [self] in
                try stillRunning(run)
                try await automationView().type(chords, until: deadline)
            }
            return VMControl.Response(ok: true)
        case .pointer:
            guard let x = request.x, let y = request.y else { throw VitrineError.invalidConfig("no coordinates") }
            let run = virtualMachine
            try await automationInput.run(until: deadline) { [self] in
                try stillRunning(run)
                let view = try automationView()
                if let sink = automationSink, sink.view === view, let size = view.guestPixelSize {
                    let scale = NSScreen.main?.backingScaleFactor ?? 2
                    sink.setViewSize(CGSize(width: size.width / scale, height: size.height / scale))
                }
                try await view.pointer(x: x, y: y, button: request.button, clicks: request.clicks ?? 1)
            }
            return VMControl.Response(ok: true)
        default:
            throw VitrineError.unsupported("not an automation request")
        }
    }

    /// Types `request.text` through the guest agent (both backends). The agent injects it as text,
    /// so any character arrives whatever the guest's keyboard layout, but only into a logged-in
    /// session the agent runs in. An agent that may not inject input (macOS without Accessibility)
    /// gets the text pasted instead, see `pasteText`. Queued with the display input so the two
    /// don't interleave.
    func handleAgentText(_ request: VMControl.Request) async throws -> VMControl.Response {
        let deadline = Date().addingTimeInterval(VMControl.automationTimeout - 2)
        guard state == .running else { throw VitrineError.invalidConfig("\(bundle.name) isn't running") }
        let text = request.text ?? ""
        guard text.count <= VMControl.maxKeyChords else {
            throw VitrineError.invalidConfig("\(text.count) characters are more than \(VMControl.maxKeyChords) at once; send them in parts")
        }
        guard let events = KeyEvent.typing(text) else {
            throw VitrineError.invalidConfig("the text has control characters other than newline and tab")
        }
        let pieces = PastedText.pieces(text)
        var via = "agent"
        try await automationInput.run(until: deadline) { [self] in
            guard state == .running, let agent, let hello = agent.guestHello else {
                throw VitrineError.unsupported("\(bundle.name)'s guest agent isn't connected (it runs once a user is logged in)")
            }
            if hello.capabilities.contains("input") {
                for event in events where !agent.send(.key(event)) {
                    throw VitrineError.backend("the guest agent disconnected while typing")
                }
                return
            }
            // The macOS agent only offers input once it may post events (Accessibility), which only
            // a person can allow. It can still set the clipboard, and ⌘V needs no permission.
            guard qemu == nil, hello.capabilities.contains("clipboard") else {
                throw VitrineError.unsupported("\(bundle.name)'s guest agent doesn't take input")
            }
            guard pieces.count(where: \.isText) <= PastedText.maxRuns else {
                throw VitrineError.invalidConfig("pasting takes about a second per line; send at most \(PastedText.maxRuns) lines at once")
            }
            try await pasteText(pieces, through: agent, until: deadline)
            via = "paste"
        }
        return VMControl.Response(ok: true, via: via)
    }

    /// Pastes text into whatever has focus: each run of it through the guest clipboard and ⌘V on
    /// the VM's keyboard, newlines and tabs as the Return and Tab keys (a pasted newline doesn't
    /// run a shell command). With clipboard sharing on, the guest clipboard then gets the Mac's
    /// content back, which it held before; otherwise the pasted text stays on it.
    private func pasteText(_ pieces: [PastedText.Piece], through agent: AgentSession, until deadline: Date) async throws {
        let view = try automationView()
        for piece in pieces {
            switch piece {
            case .key(let key):
                try await view.type([[key]], until: deadline)
            case .text(let s):
                let content = ClipboardContent(items: [.init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(s.utf8))])
                guard agent.send(.clipboard(content)) else { throw VitrineError.backend("the guest agent disconnected while pasting") }
                try await Task.sleep(nanoseconds: 300_000_000) // the agent sets its pasteboard before ⌘V arrives
                try await view.type([["meta_l", "v"]], until: deadline)
                try await Task.sleep(nanoseconds: 500_000_000) // the app reads the pasteboard while handling ⌘V
            }
        }
        if let shared = pasteboard?.snapshot() { _ = agent.send(.clipboard(shared)) }
    }

    /// Input queued behind other input belongs to the run that accepted it: a VM stopped and started
    /// again meanwhile is at a new boot or login screen the input wasn't meant for.
    private func stillRunning(_ run: VZVirtualMachine?) throws {
        guard let run, virtualMachine === run, state == .running else {
            throw VitrineError.invalidConfig("\(bundle.name) stopped before this input's turn")
        }
    }

    /// The view presenting the guest: the owner's (window or seamless sink) if it has one, else an
    /// invisible sink made for automation, closed again once the owner presents the VM itself.
    func automationView() throws -> GuestDisplayView {
        guard let vm = virtualMachine else { throw VitrineError.invalidConfig("\(bundle.name) isn't running") }
        if let v = displayViewProvider?(), v.window != nil, v.virtualMachine === vm {
            automationSink?.close()
            automationSink = nil
            return v
        }
        if let sink = automationSink { return sink.view }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw VitrineError.unsupported("no display to present \(bundle.name) on (is anyone logged in?)")
        }
        // `vitrinectl run` without --gui may not own windows; an accessory app may, without a Dock icon.
        if NSApp.activationPolicy() == .prohibited { NSApp.setActivationPolicy(.accessory) }
        let sink = DisplaySink(virtualMachine: vm, screen: screen)
        automationSink = sink
        return sink.view
    }
}

/// Runs keyboard and pointer operations one at a time. The control server handles each request in
/// its own main-actor task, and those interleave at every `await`: two typing requests would mix
/// their characters, and a click could land between another's pointer move and button press.
@MainActor
final class AutomationInputQueue {
    private var tail: Task<Void, Never>?

    /// Runs `body` after every operation queued before it; refuses it if that wait outlasts `deadline`.
    func run(until deadline: Date, _ body: @escaping @MainActor () async throws -> Void) async throws {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            guard Date() < deadline else {
                throw VitrineError.backend("waited too long for earlier keyboard or mouse input to this VM to finish; try again")
            }
            try await body()
        }
        tail = Task { @MainActor in _ = try? await task.value }
        try await task.value
    }
}

/// Text to paste, cut into runs of text and the Return and Tab keys between them.
enum PastedText {
    enum Piece: Equatable {
        case text(String)
        /// A QEMU key name (`KeyNames`).
        case key(String)
        var isText: Bool { if case .text = self { return true } else { return false } }
    }

    /// Runs one request may paste: each takes about 0.8 s, within `VMControl.automationTimeout`.
    static let maxRuns = 20

    static func pieces(_ text: String) -> [Piece] {
        var pieces: [Piece] = [], run = ""
        for ch in text {
            let key: String?
            switch ch {
            case "\n", "\r", "\r\n": key = "ret"
            case "\t": key = "tab"
            default: key = nil
            }
            guard let key else { run.append(ch); continue }
            if !run.isEmpty { pieces.append(.text(run)); run = "" }
            pieces.append(.key(key))
        }
        if !run.isEmpty { pieces.append(.text(run)) }
        return pieces
    }
}
