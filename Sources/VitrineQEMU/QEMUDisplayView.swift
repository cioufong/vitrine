import AppKit
import QuartzCore
import VitrineAgentHost

/// Shows a QEMU guest's VNC framebuffer (IOSurface-backed, aspect-fit) and forwards input.
public final class QEMUDisplayView: NSView {
    private let rfb: RFBClient
    private let imageLayer = CALayer()
    private var buttons: UInt8 = 0
    private var scrollAccumulator = CGPoint.zero
    /// Keys currently held in the guest, so modifiers pair up and nothing stays stuck on focus loss.
    private var heldKeys = Set<UInt16>()
    /// Resize the guest display to the view (in pixels) when the window size changes.
    public var autoResize = true
    /// Swap ⌘ and ⌥ for the guest (its Alt key sits where the Mac has ⌘).
    public var swapCommandOption = false
    /// Nearest-neighbour scaling (crisp pixels) instead of smooth scaling.
    public var pixelPerfect = false {
        didSet { imageLayer.magnificationFilter = pixelPerfect ? .nearest : .linear }
    }
    private var modifierSync = ModifierSync()
    private var resizeWork: DispatchWorkItem?

    public init(rfb: RFBClient) {
        self.rfb = rfb
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.magnificationFilter = .linear
        layer?.addSublayer(imageLayer)
        rfb.onFrame = { [weak self] _ in self?.refresh() }
        rfb.onResize = { [weak self] _, _ in self?.needsLayout = true; self?.refresh() }
        refresh() // reattaching to a running VM: show the current screen right away
    }

    required init?(coder: NSCoder) { fatalError() }

    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
        scheduleGuestResize()
    }

    /// Debounced: live window resizing would otherwise flood the guest with mode changes.
    private func scheduleGuestResize() {
        guard autoResize, rfb.supportsResize, let scale = window?.backingScaleFactor, bounds.width >= 320 else { return }
        let w = Int(bounds.width * scale) & ~7, h = Int(bounds.height * scale) & ~1
        guard w != rfb.width || h != rfb.height else { return }
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rfb.requestDesktopSize(width: w, height: h) }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func refresh() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let surface = rfb.currentSurface
        if imageLayer.contents as AnyObject? !== surface {
            imageLayer.contents = surface
        } else if imageLayer.responds(to: Selector(("setContentsChanged"))) {
            imageLayer.perform(Selector(("setContentsChanged")))
        } else {
            imageLayer.contents = nil; imageLayer.contents = surface
        }
        CATransaction.commit()
    }

    /// Maps a view point to framebuffer pixels, accounting for aspect-fit letterboxing.
    private func guestPoint(_ event: NSEvent) -> (Int, Int) {
        let p = convert(event.locationInWindow, from: nil)
        let fw = CGFloat(max(rfb.width, 1)), fh = CGFloat(max(rfb.height, 1))
        let scale = min(bounds.width / fw, bounds.height / fh)
        let ox = (bounds.width - fw * scale) / 2, oy = (bounds.height - fh * scale) / 2
        let x = (p.x - ox) / scale
        let y = fh - (p.y - oy) / scale // NSView is bottom-up, VNC top-down
        return (Int(x.rounded()), Int(y.rounded()))
    }

    private func sendPointer(_ e: NSEvent) { let (x, y) = guestPoint(e); rfb.pointer(x: x, y: y, buttons: buttons) }

    public override func mouseMoved(with e: NSEvent) { sendPointer(e) }
    public override func mouseDragged(with e: NSEvent) { sendPointer(e) }
    public override func rightMouseDragged(with e: NSEvent) { sendPointer(e) }
    public override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); buttons |= 1; sendPointer(e) }
    public override func mouseUp(with e: NSEvent) { buttons &= ~1; sendPointer(e) }
    public override func rightMouseDown(with e: NSEvent) { buttons |= 4; sendPointer(e) }
    public override func rightMouseUp(with e: NSEvent) { buttons &= ~4; sendPointer(e) }
    public override func otherMouseDown(with e: NSEvent) { buttons |= 2; sendPointer(e) }
    public override func otherMouseUp(with e: NSEvent) { buttons &= ~2; sendPointer(e) }

    public override func scrollWheel(with e: NSEvent) {
        // VNC scrolls in clicks (buttons 4–7); accumulate precise trackpad deltas into clicks.
        let step: CGFloat = e.hasPreciseScrollingDeltas ? 24 : 1
        scrollAccumulator.x += e.scrollingDeltaX
        scrollAccumulator.y += e.scrollingDeltaY
        let (x, y) = guestPoint(e)
        func click(_ bit: UInt8) {
            rfb.pointer(x: x, y: y, buttons: buttons | bit)
            rfb.pointer(x: x, y: y, buttons: buttons)
        }
        while scrollAccumulator.y >= step { click(8); scrollAccumulator.y -= step }
        while scrollAccumulator.y <= -step { click(16); scrollAccumulator.y += step }
        while scrollAccumulator.x >= step { click(32); scrollAccumulator.x -= step }
        while scrollAccumulator.x <= -step { click(64); scrollAccumulator.x += step }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    public override func keyDown(with e: NSEvent) { key(e, down: true) }
    public override func keyUp(with e: NSEvent) { key(e, down: false) }
    public override func flagsChanged(with e: NSEvent) {
        let (code, flags) = mapped(e)
        guard ModifierSync.isModifierKey(code) else {
            for m in modifierSync.align(to: flags.intersection(modifierSync.heldFlags)) {
                send(m.keyCode, down: m.down, characters: "")
            }
            return
        }
        modifierSync.flagsChanged(flags)
        switch Int(code) {
        case 0x39: // Caps Lock reports a state toggle: tap it in the guest
            send(code, down: true, characters: ""); send(code, down: false, characters: "")
        case 0x37, 0x36, 0x38, 0x3C, 0x3A, 0x3D, 0x3B, 0x3E:
            // Track each physical modifier key: the aggregate flags can't tell left from right.
            send(code, down: !heldKeys.contains(code), characters: "")
        default:
            return
        }
    }

    public override func resignFirstResponder() -> Bool {
        releaseAllInput()
        return super.resignFirstResponder()
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let w = window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: w)
        }
        if let newWindow {
            NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey),
                                                   name: NSWindow.didResignKeyNotification, object: newWindow)
        } else {
            releaseAllInput()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func windowResignedKey() { releaseAllInput() }

    /// Releases every key and button the guest believes is held (e.g. ⌘ held while ⌘-Tabbing away).
    private func releaseAllInput() {
        for code in heldKeys {
            rfb.key(macKeyCode: code, down: false, keysym: XTScancodes.keysym(macKeyCode: code, characters: ""))
        }
        heldKeys.removeAll()
        modifierSync = ModifierSync()
        if buttons != 0 { buttons = 0; rfb.pointer(x: 0, y: 0, buttons: 0) }
    }
    public override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self, e.type == .keyDown else { return false }
        // Keep ⌘Q / ⌘W / ⌘H for the host; everything else goes to the guest.
        if e.modifierFlags.contains(.command), ["q", "w", "h"].contains(e.charactersIgnoringModifiers ?? "") { return false }
        key(e, down: true); key(e, down: false)
        return true
    }

    private func mapped(_ e: NSEvent) -> (UInt16, NSEvent.ModifierFlags) {
        swapCommandOption ? KeyRemap.swapCommandOption(keyCode: e.keyCode, flags: e.modifierFlags) : (e.keyCode, e.modifierFlags)
    }

    /// A key press or release, preceded by any modifier changes its flags imply (synthesized input
    /// sets the flags without separate modifier events; see ModifierSync).
    private func key(_ e: NSEvent, down: Bool) {
        let (code, flags) = mapped(e)
        for m in modifierSync.align(to: flags) { send(m.keyCode, down: m.down, characters: "") }
        send(code, down: down, characters: e.charactersIgnoringModifiers ?? "")
        if !down { for m in modifierSync.releaseSynthesized() { send(m.keyCode, down: m.down, characters: "") } }
    }

    private func send(_ code: UInt16, down: Bool, characters: String) {
        if down { heldKeys.insert(code) } else { heldKeys.remove(code) }
        rfb.key(macKeyCode: code, down: down, keysym: XTScancodes.keysym(macKeyCode: code, characters: characters))
    }
}
