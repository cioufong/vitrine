import AppKit
import Virtualization
import VitrineAgentHost
import VitrineCore

/// VZVirtualMachineView with Vitrine's keyboard handling: modifiers that arrive only as flags on a
/// key event (synthesized input) are pressed first, ⌘/⌥ can be swapped for the guest, and key
/// combinations can be sent from a menu.
public final class GuestDisplayView: VZVirtualMachineView {
    /// Swap ⌘ and ⌥ for the guest (Windows and Linux put Alt where the Mac has ⌘).
    public var swapCommandOption = false
    private var modifierSync = ModifierSync()

    public override func flagsChanged(with e: NSEvent) {
        let event = mapped(e)
        guard ModifierSync.isModifierKey(event.keyCode) else {
            // Modifier state without its key (posted with key code 0). Releases are replayed with
            // the modifiers' own key codes here; presses wait for the key they modify (keyDown).
            apply(modifierSync.align(to: event.modifierFlags.intersection(modifierSync.heldFlags)), like: event)
            return
        }
        modifierSync.flagsChanged(event.modifierFlags)
        super.flagsChanged(with: event)
    }

    public override func keyDown(with e: NSEvent) {
        let event = mapped(e)
        apply(modifierSync.align(to: wantedFlags(event)), like: event)
        super.keyDown(with: event)
    }

    public override func keyUp(with e: NSEvent) {
        let event = mapped(e)
        apply(modifierSync.align(to: wantedFlags(event)), like: event)
        super.keyUp(with: event)
        apply(modifierSync.releaseSynthesized(), like: event)
    }

    private func wantedFlags(_ e: NSEvent) -> NSEvent.ModifierFlags {
        modifierSync.wanted(e.modifierFlags, characters: e.characters, ignoringModifiers: e.charactersIgnoringModifiers)
    }

    public override func resignFirstResponder() -> Bool {
        modifierSync = ModifierSync()
        return super.resignFirstResponder()
    }

    /// Presses `combo` in order and releases it in reverse.
    public func send(_ combo: SendKeyCombo) {
        press(combo.keyCodes)
    }

    /// Presses Mac key codes in order and releases them in reverse.
    private func press(_ codes: [UInt16]) {
        guard let window else { return }
        var flags: NSEvent.ModifierFlags = []
        func post(_ code: UInt16, down: Bool) {
            if let flag = SendKeyCombo.modifierFlag(code) {
                if down { flags.insert(flag) } else { flags.remove(flag) }
                super.flagsChanged(with: Self.event(.flagsChanged, code: code, flags: flags, window: window))
            } else {
                let e = Self.event(down ? .keyDown : .keyUp, code: code, flags: flags, window: window)
                if down { super.keyDown(with: e) } else { super.keyUp(with: e) }
            }
        }
        for code in codes { post(code, down: true) }
        for code in codes.reversed() { post(code, down: false) }
    }

    // MARK: Automation (VMControl: keys, pointer, screenshot)

    /// Presses each chord of QEMU key names together and releases it (see `KeyNames`), pausing
    /// briefly between chords so the guest sees separate key strokes. Stops at `deadline`, when
    /// whoever asked stops waiting, rather than typing on unobserved.
    public func type(_ chords: [[String]], until deadline: Date = .distantFuture) async throws {
        guard window != nil else { throw VitrineError.unsupported("the VM's display isn't presented") }
        let codes = try chords.map { chord in
            try chord.map { name in
                guard let code = KeyNames.macKeyCodes[name] else { throw VitrineError.invalidConfig("unknown key \(name)") }
                return code
            }
        }
        for (n, chord) in codes.enumerated() {
            guard Date() < deadline else {
                throw VitrineError.backend("ran out of time after typing \(n) of \(codes.count) keys")
            }
            press(chord)
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
    }

    /// The guest display's size in pixels.
    public var guestPixelSize: CGSize? {
        if let s = virtualMachine?.graphicsDevices.first?.displays.first?.sizeInPixels, s.width > 0 { return s }
        return Thumbnailer.surface(in: self).map { CGSize(width: $0.width, height: $0.height) }
    }

    /// Where guest pixel (x, y) (origin top left) is drawn in this view, which shows the display
    /// scaled to fit and centered.
    func viewPoint(guestX x: Double, y: Double, guestSize g: CGSize) -> NSPoint {
        let scale = min(bounds.width / g.width, bounds.height / g.height)
        let ox = (bounds.width - g.width * scale) / 2, oy = (bounds.height - g.height * scale) / 2
        let px = ox + (x + 0.5) * scale
        let py = isFlipped ? oy + (y + 0.5) * scale : bounds.height - oy - (y + 0.5) * scale
        return NSPoint(x: px, y: py)
    }

    /// Moves the guest pointer to pixel (x, y) and, with a button, clicks there `clicks` times.
    public func pointer(x: Int, y: Int, button: String?, clicks: Int) async throws {
        guard let window else { throw VitrineError.unsupported("the VM's display isn't presented") }
        guard let size = guestPixelSize else { throw VitrineError.unsupported("the guest display has no size yet") }
        guard x >= 0, y >= 0, Double(x) < size.width, Double(y) < size.height else {
            throw VitrineError.invalidConfig("(\(x), \(y)) is outside the \(Int(size.width))×\(Int(size.height)) display")
        }
        let location = convert(viewPoint(guestX: Double(x), y: Double(y), guestSize: size), to: nil)
        func event(_ type: NSEvent.EventType, clickCount: Int = 0) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount,
                               pressure: type == .leftMouseDown || type == .rightMouseDown ? 1 : 0)!
        }
        mouseMoved(with: event(.mouseMoved))
        try? await Task.sleep(nanoseconds: 50_000_000)
        guard let button else { return }
        let right = button == "right"
        guard right || button == "left" else { throw VitrineError.invalidConfig("button must be left or right") }
        for n in 1...max(1, min(clicks, 3)) {
            if right { rightMouseDown(with: event(.rightMouseDown, clickCount: n)) } else { mouseDown(with: event(.leftMouseDown, clickCount: n)) }
            try? await Task.sleep(nanoseconds: 30_000_000)
            if right { rightMouseUp(with: event(.rightMouseUp, clickCount: n)) } else { mouseUp(with: event(.leftMouseUp, clickCount: n)) }
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
    }

    /// Writes the guest display at full resolution as PNG; returns its size in pixels.
    public func screenshot(to url: URL) throws -> CGSize {
        guard let surface = Thumbnailer.surface(in: self),
              let png = Thumbnailer.png(from: surface, maxWidth: .greatestFiniteMagnitude) else {
            throw VitrineError.unsupported("the guest display has no frame yet")
        }
        try png.write(to: url, options: .atomic)
        return CGSize(width: surface.width, height: surface.height)
    }

    /// Mean red, green, blue (0–255) of the guest pixels in `rect` (origin top left) in the frame shown
    /// now. Cheap enough to poll: timing tools watch a patch of the screen change with it.
    public func meanColor(in rect: CGRect) throws -> [Double] {
        guard let surface = Thumbnailer.surface(in: self) else { throw VitrineError.unsupported("the guest display has no frame yet") }
        guard let color = Thumbnailer.meanColor(of: CIImage(ioSurface: surface), in: rect) else {
            throw VitrineError.invalidConfig("\(rect) is outside the \(surface.width)×\(surface.height) display")
        }
        return color
    }

    /// The event as the guest should get it: ⌘/⌥ swapped when asked, and with device modifier bits
    /// that match its flags. Events posted by automation and remote-control apps often carry Shift
    /// without its device bit, which Virtualization.framework reads as Shift released.
    private func mapped(_ e: NSEvent) -> NSEvent {
        guard let window = e.window ?? window else { return e }
        var (code, flags) = (e.keyCode, e.modifierFlags)
        if swapCommandOption { (code, flags) = KeyRemap.swapCommandOption(keyCode: code, flags: flags) }
        flags = DeviceModifierBits.reconciled(flags, keyCode: e.type == .flagsChanged ? code : nil)
        guard code != e.keyCode || flags != e.modifierFlags else { return e }
        return Self.event(e.type, code: code, flags: flags, window: window, characters: e.type == .flagsChanged ? "" : e.characters ?? "",
                          ignoringModifiers: e.type == .flagsChanged ? "" : e.charactersIgnoringModifiers ?? "", isARepeat: e.type == .keyDown && e.isARepeat)
    }

    /// Sends modifier presses/releases as `flagsChanged` events, as a keyboard would.
    private func apply(_ changes: [ModifierSync.Change], like e: NSEvent) {
        guard let window = e.window ?? window else { return }
        for c in changes {
            super.flagsChanged(with: Self.event(.flagsChanged, code: c.keyCode, flags: c.flags, window: window))
        }
    }

    static func event(_ type: NSEvent.EventType, code: UInt16, flags: NSEvent.ModifierFlags, window: NSWindow,
                      characters: String = "", ignoringModifiers: String = "", isARepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: DeviceModifierBits.reconciled(flags, keyCode: type == .flagsChanged ? code : nil),
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: ignoringModifiers, isARepeat: isARepeat, keyCode: code)!
    }
}
