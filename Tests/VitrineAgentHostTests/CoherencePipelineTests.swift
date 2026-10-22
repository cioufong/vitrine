import XCTest
import AppKit
@testable import VitrineAgentProtocol
@testable import VitrineAgentHost

@MainActor
final class CoherencePipelineTests: XCTestCase {
    func testSyntheticGuestProducesHostWindows() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("Coherence windows require an active GUI display")
        }
        let guest = SyntheticGuest(widthPoints: 800, heightPoints: 600, scale: 2)
        defer { guest.hostSession.close() }
        let cc = CoherenceController(session: guest.hostSession, screen: screen)
        let ready = expectation(description: "ready")
        guest.hostSession.onStateChange = { if case .ready = $0 { ready.fulfill() } }
        guest.start()
        wait(for: [ready], timeout: 5)
        cc.start()
        let deadline = Date().addingTimeInterval(5)
        while (cc.windowCount < 2 || guest.hostSession.framebuffer.width == 0) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(cc.windowCount, 2,
                       "display=\(String(describing: guest.hostSession.display)) windows=\(guest.hostSession.windows.count) fb=\(guest.hostSession.framebuffer.width)")
        XCTAssertEqual(guest.hostSession.framebuffer.width, 1600)
        // Every window must end up displaying the shared framebuffer surface.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(cc.layerSurfaces.count, 2)
        for s in cc.layerSurfaces { XCTAssertTrue(s === guest.hostSession.framebuffer.surface) }
        // ⌃⌘C inside a Coherence window asks to leave Coherence; other keys go to the guest.
        var exitRequested = false
        cc.onExit = { exitRequested = true }
        let view = try XCTUnwrap(cc.firstWindowContentView)
        view.window?.makeKey()
        func keyEvent(_ chars: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                             windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: chars,
                             charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 8)!
        }
        _ = view.performKeyEquivalent(with: keyEvent("c", [.command, .control]))
        XCTAssertTrue(exitRequested || view.window?.isKeyWindow == false,
                      "⌃⌘C should request exit when the window is key")
        cc.stop()
        XCTAssertEqual(cc.windowCount, 0)
    }
}
