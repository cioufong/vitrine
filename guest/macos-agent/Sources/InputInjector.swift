import AppKit
import ApplicationServices
import VitrineAgentProtocol

/// Replays host input inside the guest. Requires the Accessibility permission.
final class InputInjector {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttonsDown: Set<PointerEvent.Button> = []
    private var keysDown: Set<UInt16> = []
    /// Every event leaves through here, so tests can record events instead of posting host input.
    private let post: (CGEvent) -> Void

    init(post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.post = post
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func pointer(_ e: PointerEvent) {
        let p = CGPoint(x: CGFloat(e.x), y: CGFloat(e.y))
        let flags = CGEventFlags(rawValue: e.modifiers)
        let cgButton: CGMouseButton = e.button == .left ? .left : (e.button == .right ? .right : .center)
        let event: CGEvent?
        switch e.kind {
        case .move:
            event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)
        case .down:
            buttonsDown.insert(e.button)
            let t: CGEventType = e.button == .left ? .leftMouseDown : (e.button == .right ? .rightMouseDown : .otherMouseDown)
            event = CGEvent(mouseEventSource: source, mouseType: t, mouseCursorPosition: p, mouseButton: cgButton)
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(e.clickCount))
        case .up:
            buttonsDown.remove(e.button)
            let t: CGEventType = e.button == .left ? .leftMouseUp : (e.button == .right ? .rightMouseUp : .otherMouseUp)
            event = CGEvent(mouseEventSource: source, mouseType: t, mouseCursorPosition: p, mouseButton: cgButton)
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(e.clickCount))
        case .drag:
            let t: CGEventType = e.button == .left ? .leftMouseDragged : (e.button == .right ? .rightMouseDragged : .otherMouseDragged)
            event = CGEvent(mouseEventSource: source, mouseType: t, mouseCursorPosition: p, mouseButton: cgButton)
        case .scroll:
            // Warp first so the scroll lands in the window under the pointer.
            if let warp = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) {
                post(warp)
            }
            event = CGEvent(scrollWheelEvent2Source: source, units: e.preciseScroll ? .pixel : .line, wheelCount: 2,
                            wheel1: Int32(e.scrollDY.rounded()), wheel2: Int32(e.scrollDX.rounded()), wheel3: 0)
        }
        event?.flags = flags
        if let event { post(event) }
    }

    /// Releases everything injected as held, e.g. when the host disconnects mid-shortcut or mid-drag.
    func releaseAll() {
        for code in keysDown {
            if let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: false) { post(up) }
        }
        keysDown.removeAll()
        let p = CGEvent(source: nil)?.location ?? .zero
        for b in buttonsDown {
            let (t, cg): (CGEventType, CGMouseButton) = b == .left ? (.leftMouseUp, .left) : b == .right ? (.rightMouseUp, .right) : (.otherMouseUp, .center)
            if let up = CGEvent(mouseEventSource: source, mouseType: t, mouseCursorPosition: p, mouseButton: cg) { post(up) }
        }
        buttonsDown.removeAll()
    }

    func key(_ e: KeyEvent) {
        // 0xffff is the protocol's text-only sentinel, not a valid macOS virtual key code.
        // Use the same valid code for construction and held-key teardown; Unicode supplies the text.
        let keyCode: UInt16 = e.keyCode == 0xffff ? 0 : e.keyCode
        if e.down { keysDown.insert(keyCode) } else { keysDown.remove(keyCode) }
        let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: e.down)
        let flags = CGEventFlags(rawValue: e.modifiers)
        event?.flags = flags
        // Attach the host's characters for plain typing so text arrives intact even when the key code
        // doesn't match (synthesized input). Shortcuts keep pure key codes so ⌘C etc. map correctly.
        let isShortcut = flags.contains(.maskCommand) || flags.contains(.maskControl)
        if !isShortcut, !e.text.isEmpty, !e.text.unicodeScalars.contains(where: { $0.value < 0x20 || (0xF700...0xF8FF).contains($0.value) }) {
            let utf16 = Array(e.text.utf16)
            event?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        }
        if let event { post(event) }
    }

    /// Focus/close/move/resize a guest window through the Accessibility API.
    func perform(_ action: WindowAction, windows: [WindowInfo]) {
        guard let info = windows.first(where: { $0.id == action.windowID }) else { return }
        let app = NSRunningApplication(processIdentifier: info.pid)
        if action.action == .focus { app?.activate() }
        guard let axWindow = Self.axWindow(pid: info.pid, matching: info) else { return }
        switch action.action {
        case .focus:
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        case .close:
            if let button = Self.attribute(axWindow, kAXCloseButtonAttribute) {
                AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            }
        case .minimize:
            AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        case .zoom:
            if let button = Self.attribute(axWindow, kAXZoomButtonAttribute) {
                AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            }
        case .move, .resize:
            guard let f = action.frame else { return }
            var origin = CGPoint(x: f.x, y: f.y)
            var size = CGSize(width: f.width, height: f.height)
            if let v = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, v) }
            if action.action == .resize, let v = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, v)
            }
        }
    }

    static func attribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }

    /// Finds the AX window whose frame best matches the CG window.
    static func axWindow(pid: pid_t, matching info: WindowInfo) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        var best: (AXUIElement, Double)?
        for w in windows {
            var origin = CGPoint.zero, size = CGSize.zero
            if let p = attribute(w, kAXPositionAttribute) { AXValueGetValue(p as! AXValue, .cgPoint, &origin) }
            if let s = attribute(w, kAXSizeAttribute) { AXValueGetValue(s as! AXValue, .cgSize, &size) }
            let d = abs(origin.x - info.frame.x) + abs(origin.y - info.frame.y)
                + abs(size.width - info.frame.width) + abs(size.height - info.frame.height)
            let title = attribute(w, kAXTitleAttribute) as? String ?? ""
            let score = d - (title == info.title && !title.isEmpty ? 50 : 0)
            if best == nil || score < best!.1 { best = (w, score) }
        }
        return best?.0
    }
}
