import XCTest
import VitrineCore
import VitrineQEMU
import VitrineAgentHost
import VitrineAgentProtocol
@testable import vitrinectl

/// Clipboard text the scripted guest sends unprompted; the probe must never print it.
private let privateClipboard = "fixture-unexpected-clipboard-do-not-print"

/// Runs the real `AgentProbe` against scripted guests: no VM, no agent, no host input. Each fault
/// breaks one step the probe checks, and the probe must fail with a reason naming that step.
@MainActor
final class AgentProbeTests: XCTestCase {
    func testCaptureOnly() async throws { try await expectPass(editor: nil) }
    func testEditorRoundTrip() async throws { try await expectPass(editor: "Probe Fixture") }

    func testHandshakeDropped() async throws { try await expectFailure("handshake", .handshakeDropped) }
    func testMissingDisplay() async throws { try await expectFailure("display info", .missingDisplay) }
    func testMissingFrames() async throws { try await expectFailure("coherence capture", .missingFrames) }
    func testMissingWindows() async throws { try await expectFailure("window list", .missingWindows) }
    func testMissingCoherence() async throws { try await expectFailure("Screen Recording", .missingCoherence) }
    func testUnsupportedBackend() async throws { try await expectFailure("QEMU", backend: .vz) }
    func testFrameWithoutSurface() async throws {
        let png = URL(fileURLWithPath: "/no-such-vitrine-fixture-directory/frame.png")
        try await expectFailure("surface", png: png)
    }

    func testMissingEditor() async throws { try await expectFailure("editor window", editor: "absent fixture") }
    func testEmptyEditor() async throws { try await expectFailure("non-empty", editor: "") }
    func testFocusFailed() async throws { try await expectFailure("focus window", .focusFailed, editor: "Probe Fixture") }
    func testGuestClipboardFailed() async throws {
        try await expectFailure("guest→host clipboard", .guestClipboardFailed, editor: "Probe Fixture")
    }
    func testHostClipboardFailed() async throws {
        try await expectFailure("host→guest clipboard", .hostClipboardFailed, editor: "Probe Fixture")
    }
    func testMissingInput() async throws { try await expectFailure("Accessibility", .missingInput, editor: "Probe Fixture") }
    func testMissingClipboard() async throws { try await expectFailure("clipboard", .missingClipboard, editor: "Probe Fixture") }

    // MARK: Through the CLI: `runAsync`/`die` turn the probe's outcome into the exit status.

    func testCLICaptureOnlyExitsZero() async throws {
        let (status, output) = try await runCLI(editor: nil)
        XCTAssertEqual(status, 0, output)
        XCTAssertFalse(output.contains(privateClipboard), "unexpected clipboard content was emitted")
    }

    func testCLIMissingEditorExitsOne() async throws {
        let (status, output) = try await runCLI(editor: "absent fixture")
        XCTAssertEqual(status, 1, output)
        XCTAssertTrue(output.contains("editor window"), output)
        XCTAssertFalse(output.contains(privateClipboard), "unexpected clipboard content was emitted")
    }

    // MARK: Helpers

    private struct Outcome {
        var error: Error?
        var guest: ScriptedGuest?
        var output: String
    }

    private func expectPass(editor: String?) async throws {
        let outcome = try await probe(.none, backend: .qemu, editor: editor, png: nil)
        XCTAssertNil(outcome.error, "unexpected probe error: \(outcome.error?.localizedDescription ?? "")")
        try checkTeardown(outcome, mayType: mayType(editor, .none))
    }

    private func expectFailure(_ reason: String, _ fault: ScriptedGuest.Fault = .none, backend: VMConfig.Backend = .qemu,
                               editor: String? = nil, png: URL? = nil) async throws {
        let outcome = try await probe(fault, backend: backend, editor: editor, png: png)
        let failure = try XCTUnwrap(outcome.error, "failed probe returned success").localizedDescription
        XCTAssertTrue(failure.contains(reason), "wrong failure: \(failure)")
        XCTAssertFalse(failure.contains(privateClipboard), "unexpected clipboard content in the failure")
        try checkTeardown(outcome, mayType: mayType(editor, fault))
    }

    /// Only a probe that found the editor may type, and never into a guest without input/clipboard support.
    private func mayType(_ editor: String?, _ fault: ScriptedGuest.Fault) -> Bool {
        editor == ScriptedGuest.editor.title && ![.missingInput, .missingClipboard].contains(fault)
    }

    private func checkTeardown(_ outcome: Outcome, mayType: Bool) throws {
        XCTAssertFalse(outcome.output.contains(privateClipboard), "unexpected clipboard content was emitted")
        guard let guest = outcome.guest else { return }
        XCTAssertTrue(guest.closed, "agent channel not closed")
        if guest.coherence.contains(true) { XCTAssertEqual(guest.coherence.last, false, "Coherence was not disabled on exit") }
        if !mayType { XCTAssertEqual(guest.inputCount, 0, "input injected despite missing prerequisite") }
    }

    private func makeBundle(backend: VMConfig.Backend) throws -> VMBundle {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-probe-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        var config = VMConfig(name: "fixture-vm", guestOS: .linux)
        config.backend = backend
        return try VMBundle.create(at: dir.appendingPathComponent("fixture-vm.\(VMBundle.pathExtension)"), config: config)
    }

    /// Runs the probe with stdout captured, so the privacy check sees everything it printed.
    private func probe(_ fault: ScriptedGuest.Fault, backend: VMConfig.Backend, editor: String?, png: URL?) async throws -> Outcome {
        let bundle = try makeBundle(backend: backend)
        let log = bundle.url.appendingPathComponent("probe.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        var guest: ScriptedGuest?
        var error: Error?
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        dup2(handle.fileDescriptor, STDOUT_FILENO)
        do {
            try await AgentProbe.run(bundle: bundle, framePNG: png, editorTitle: editor) { _, _, _ in
                let g = ScriptedGuest(fault)
                guest = g
                return g
            }
        } catch let e { error = e }
        fflush(stdout)
        dup2(saved, STDOUT_FILENO)
        close(saved)
        let output = try String(contentsOf: log, encoding: .utf8)
        // Keep the probe's report in the test log, minus the dummy private clipboard.
        print(output.replacingOccurrences(of: privateClipboard, with: "<redacted fixture clipboard>"), terminator: "")
        fflush(stdout)
        return Outcome(error: error, guest: guest, output: output)
    }

    /// Runs the built `vitrinectl agent probe` against a scripted guest listening on the bundle's agent socket.
    private func runCLI(editor: String?) async throws -> (status: Int32, output: String) {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = products.appendingPathComponent("vitrinectl")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else {
            throw VitrineError.fileNotFound("vitrinectl next to the test bundle in \(products.path)")
        }
        let bundle = try makeBundle(backend: .qemu)
        let guest = try SocketGuest(path: QEMUSockets(directory: bundle.socketDirectory).agent.path)
        addTeardownBlock { guest.stop() }
        guest.accept()

        let log = bundle.url.appendingPathComponent("cli.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = cli
        process.arguments = ["agent", "probe", bundle.url.path] + (editor.map { ["--editor", $0] } ?? [])
        process.standardOutput = handle
        process.standardError = handle
        // The guest answers on the main queue, so wait without blocking it.
        let status: Int32 = try await withCheckedThrowingContinuation { done in
            process.terminationHandler = { done.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { done.resume(throwing: error) }
        }
        let output = try String(contentsOf: log, encoding: .utf8)
        print(output.replacingOccurrences(of: privateClipboard, with: "<redacted fixture clipboard>"), terminator: "")
        fflush(stdout)
        return (status, output)
    }
}

/// An agent connection whose guest is a script: a 4x4 display with one editor window that keeps
/// typed text, ⌘A/⌘C/⌘V and the clipboard roughly like TextEdit.
final class ScriptedGuest: AgentProbeSession {
    enum Fault {
        case none, handshakeDropped, missingDisplay, missingFrames, missingWindows, missingCoherence
        case missingInput, missingClipboard, focusFailed, guestClipboardFailed, hostClipboardFailed
    }

    private let fault: Fault
    private var readinessReads = 0
    var isReady: Bool {
        readinessReads += 1
        // Connection is selected, then closes before the required ready check.
        return fault != .handshakeDropped || readinessReads <= 2
    }
    let guestHello: Hello?
    let display: DisplayInfo?
    var windows: [WindowInfo] = []
    let framebuffer = GuestFramebuffer()
    var onFrame: ((Rect) -> Void)?
    var onClipboard: ((ClipboardContent) -> Void)?
    var onLog: ((String) -> Void)?
    private(set) var coherence: [Bool] = []
    private(set) var closed = false
    private(set) var inputCount = 0
    private var text = ""
    private var clipboard = ""
    private var selected = false
    private var copies = 0

    init(_ fault: Fault) {
        self.fault = fault
        var caps = ["coherence", "input", "clipboard"]
        if fault == .missingCoherence { caps.removeAll { $0 == "coherence" } }
        if fault == .missingInput { caps.removeAll { $0 == "input" } }
        if fault == .missingClipboard { caps.removeAll { $0 == "clipboard" } }
        guestHello = Hello(role: "guest", os: "fixture OS", agentVersion: "fixture", capabilities: caps)
        display = fault == .missingDisplay ? nil : DisplayInfo(widthPoints: 4, heightPoints: 4, scale: 1, menuBarHeight: 0)
    }

    static let editor = WindowInfo(id: 7, pid: 1, appName: "Fixture Editor", bundleID: nil, title: "Probe Fixture",
                                   frame: Rect(x: 0, y: 0, width: 4, height: 4), layer: 0, kind: .normal, isFocused: false)

    func start() {}
    func close() { closed = true }

    func setCoherence(_ enabled: Bool, maxFPS: Int) {
        coherence.append(enabled)
        guard enabled else { return }
        onClipboard?(Self.plainText(privateClipboard))
        if fault != .missingWindows { windows = [Self.editor] }
        if fault != .missingFrames { onFrame?(Rect(x: 0, y: 0, width: 4, height: 4)) }
    }

    @discardableResult func send(_ message: AgentMessage) -> Bool {
        switch message {
        case .windowAction:
            if fault != .focusFailed { windows[0].isFocused = true }
        case .clipboard(let content):
            if fault != .hostClipboardFailed, let item = content.items.first {
                clipboard = String(decoding: item.data, as: UTF8.self)
            }
        case .key(let key):
            inputCount += 1
            guard key.down else { return true }
            if key.modifiers & (1 << 20) != 0 { // ⌘
                switch key.keyCode {
                case 0x00: selected = true
                case 0x08:
                    copies += 1
                    if fault != .guestClipboardFailed {
                        // A guest that ignored the host's clipboard copies back something unrelated.
                        onClipboard?(Self.plainText(fault == .hostClipboardFailed && copies > 1 ? privateClipboard : text))
                    }
                case 0x09: if selected { text = "" }; text += clipboard; selected = false
                default: break
                }
            } else if key.keyCode == 0x33 {
                if selected { text = ""; selected = false }
            } else if !key.text.isEmpty {
                if selected { text = ""; selected = false }
                text += key.text
            }
        default: break
        }
        return true
    }

    static func plainText(_ s: String) -> ClipboardContent {
        ClipboardContent(items: [.init(type: "public.utf8-plain-text", data: Data(s.utf8))])
    }
}

/// The far end of the agent socket for the CLI tests: a guest that completes the handshake and
/// streams one window and one frame, like an agent with Screen Recording allowed.
final class SocketGuest {
    private let path: String
    private let listener: Int32
    private var channel: AgentChannel?

    init(path: String) throws {
        self.path = path
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        unlink(path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: path.utf8.prefix(raw.count - 1))
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard listener >= 0, bound == 0, listen(listener, 1) == 0 else {
            throw VitrineError.io("can't listen on \(path): \(String(cString: strerror(errno)))")
        }
    }

    /// Accepts the probe's one connection off the main thread, then answers it on the main queue.
    func accept() {
        let listener = listener
        DispatchQueue.global().async {
            let fd = Darwin.accept(listener, nil, nil)
            guard fd >= 0 else { return }
            DispatchQueue.main.async { self.serve(AgentChannel(fileDescriptor: fd)) }
        }
    }

    private func serve(_ channel: AgentChannel) {
        self.channel = channel
        channel.start(callbackQueue: .main, onMessage: { [weak channel] message in
            guard let channel else { return }
            switch message {
            case .hello:
                channel.send(.hello(Hello(role: "guest", os: "fixture OS", agentVersion: "fixture",
                                          capabilities: ["coherence", "input", "clipboard"])))
                channel.send(.displayInfo(DisplayInfo(widthPoints: 4, heightPoints: 4, scale: 1, menuBarHeight: 0)))
            case .setCoherence(let request) where request.enabled:
                channel.send(.clipboard(ScriptedGuest.plainText(privateClipboard)))
                channel.send(.windowList(WindowList(windows: [ScriptedGuest.editor])))
                channel.send(.frame(FrameUpdate(surfaceWidth: 4, surfaceHeight: 4, x: 0, y: 0, width: 4, height: 4,
                                                data: Data(count: 4 * 4 * 4))))
            case .ping(let nonce):
                channel.send(.pong(nonce))
            default: break
            }
        }, onClose: { _ in })
    }

    func stop() {
        Darwin.close(listener)
        channel?.close()
        // The bundle's own socket directory, unique to this test's temporary bundle.
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }
}
