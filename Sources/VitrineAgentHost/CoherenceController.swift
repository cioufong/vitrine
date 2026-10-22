import AppKit
import QuartzCore
import VitrineAgentProtocol

/// Mirrors every guest window as its own host NSWindow (Coherence mode).
///
/// All windows share the session's IOSurface framebuffer; each layer shows its window's sub-rect via
/// `contentsRect`, so a frame update costs one memcpy regardless of how many windows are open.
@MainActor
public final class CoherenceController {
    public private(set) var isActive = false
    public var onExit: (() -> Void)?
    /// Files dragged onto a Coherence window, with the guest point they were dropped at.
    public var onFileDrop: (([URL], CGPoint) -> Void)?
    /// Guest apps that currently have regular windows (for Dock icons), whenever the set changes.
    public var onAppsChanged: (([GuestApp]) -> Void)?
    private var lastApps: [GuestApp] = []

    public struct GuestApp: Equatable, Sendable {
        public var key: String
        public var name: String
    }

    private let session: AgentSession
    private var windows: [UInt32: CoherenceWindow] = [:]
    private var order: [UInt32] = []
    private var geometry: CoherenceGeometry?
    private var screen: NSScreen
    private var previousHandlers: (windows: (([WindowInfo]) -> Void)?, frame: ((Rect) -> Void)?, display: ((DisplayInfo) -> Void)?)

    public init(session: AgentSession, screen: NSScreen) {
        self.session = session
        self.screen = screen
    }

    public var windowCount: Int { windows.count }
    /// Surfaces currently bound to each window's layer (diagnostics/tests).
    var layerSurfaces: [IOSurface?] { windows.values.map(\.boundSurface) }
    var firstWindowContentView: NSView? { windows.values.first?.contentView }

    public func start(maxFPS: Int = 60) {
        guard !isActive else { return }
        isActive = true
        previousHandlers = (session.onWindowsChanged, session.onFrame, session.onDisplayChanged)
        session.onWindowsChanged = { [weak self] list in
            self?.previousHandlers.windows?(list)
            self?.sync(list)
        }
        session.onFrame = { [weak self] rect in
            self?.previousHandlers.frame?(rect)
            self?.refresh(dirtyPixels: rect)
        }
        session.onDisplayChanged = { [weak self] info in
            self?.previousHandlers.display?(info)
            self?.updateGeometry(info)
        }
        if let d = session.display { updateGeometry(d) }
        session.setCoherence(true, maxFPS: maxFPS)
    }

    public func stop() {
        guard isActive else { return }
        isActive = false
        session.setCoherence(false)
        session.onWindowsChanged = previousHandlers.windows
        session.onFrame = previousHandlers.frame
        session.onDisplayChanged = previousHandlers.display
        for w in windows.values { w.orderOut(nil) }
        windows.removeAll()
        order.removeAll()
        if !lastApps.isEmpty { lastApps = []; onAppsChanged?([]) }
    }

    /// Brings every window of a guest app forward (Dock icon clicked) and focuses its front one.
    @discardableResult
    public func activateApp(key: String) -> Int {
        let ids = order.filter { windows[$0]?.info.appKey == key }
        guard let front = ids.first else { return 0 }
        let raise = { [weak self] in
            guard let self else { return }
            for id in ids.reversed() { self.windows[id]?.orderFront(nil) }
            self.windows[front]?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
        raise()
        // Activation completes asynchronously and then brings the previous key window (e.g. the
        // Control Center) back up; raise the app's windows again once it has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: raise)
        session.send(.windowAction(WindowAction(windowID: front, action: .focus)))
        return ids.count
    }

    /// Whether `window` shows one of this session's guest windows.
    public func owns(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return windows.values.contains { $0 === window }
    }

    /// Asks the guest to close every window of an app (Quit from its Dock icon).
    public func closeApp(key: String) {
        for (id, w) in windows where w.info.appKey == key && w.info.kind == .normal {
            session.send(.windowAction(WindowAction(windowID: id, action: .close)))
        }
    }

    private func publishApps(_ list: [WindowInfo]) {
        var seen = Set<String>()
        let apps = list.filter { $0.kind == .normal }.compactMap { w -> GuestApp? in
            seen.insert(w.appKey).inserted ? GuestApp(key: w.appKey, name: w.appName) : nil
        }.sorted { $0.key < $1.key }
        guard apps != lastApps else { return }
        lastApps = apps
        onAppsChanged?(apps)
    }

    private func updateGeometry(_ info: DisplayInfo) {
        geometry = CoherenceGeometry(hostScreenFrame: screen.frame, display: info)
        sync(session.windows)
    }

    /// Reconciles host windows with the guest's front-to-back window list.
    private func sync(_ list: [WindowInfo]) {
        guard isActive, let geometry else { return }
        publishApps(list)
        // One snapshot for the whole pass: the frame queue may reallocate the surface mid-loop.
        let surface = session.framebuffer.snapshot().surface
        let live = Set(list.map(\.id))
        for (id, w) in windows where !live.contains(id) {
            w.orderOut(nil)
            windows[id] = nil
        }
        for info in list {
            let frame = geometry.hostRect(forGuest: info.frame)
            // NSWindow raises (uncatchable from Swift) on non-finite frames; skip anything implausible.
            guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
                  frame.width >= 1, frame.height >= 1 else { continue }
            let window: CoherenceWindow
            if let existing = windows[info.id] {
                window = existing
            } else {
                window = CoherenceWindow(info: info, controller: self)
                windows[info.id] = window
            }
            window.update(info: info, frame: frame, contentsRect: geometry.contentsRect(forGuest: info.frame),
                          surface: surface)
        }
        // Stack host windows to match guest z-order (list is front-to-back).
        let ids = list.map(\.id)
        if ids != order {
            var above: CoherenceWindow?
            for id in ids {
                guard let w = windows[id] else { continue }
                if let above { w.order(.below, relativeTo: above.windowNumber) } else { w.orderFront(nil) }
                above = w
            }
            order = ids
        }
        if let focused = list.first(where: \.isFocused), let w = windows[focused.id], NSApp.isActive, !w.isKeyWindow {
            w.makeKey()
        }
    }

    private func refresh(dirtyPixels: Rect) {
        guard isActive, let geometry else { return }
        let s = geometry.display.scale
        let dirty = Rect(x: dirtyPixels.x / s, y: dirtyPixels.y / s, width: dirtyPixels.width / s, height: dirtyPixels.height / s)
        for w in windows.values where !w.info.frame.intersection(dirty).isEmpty {
            w.contentsChanged(surface: session.framebuffer.snapshot().surface)
        }
    }

    // MARK: Input from host windows

    func guestPoint(fromHostScreen p: NSPoint) -> CGPoint {
        geometry?.guestPoint(forHost: p) ?? .zero
    }

    func send(_ message: AgentMessage) { session.send(message) }

    func windowDidBecomeKey(_ id: UInt32) {
        session.send(.windowAction(WindowAction(windowID: id, action: .focus)))
    }

    func fileDrop(_ urls: [URL], atHost point: NSPoint) {
        onFileDrop?(urls, guestPoint(fromHostScreen: point))
    }

    func requestClose(_ id: UInt32) {
        session.send(.windowAction(WindowAction(windowID: id, action: .close)))
    }
}

/// Borderless host window displaying one guest window.
@MainActor
final class CoherenceWindow: NSWindow {
    private(set) var info: WindowInfo
    private weak var controller: CoherenceController?
    private let surfaceLayer = CALayer()

    init(info: WindowInfo, controller: CoherenceController) {
        self.info = info
        self.controller = controller
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = info.kind != .menu
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.managed, .participatesInCycle, .fullScreenNone]
        level = Self.level(for: info.kind)
        let view = CoherenceView(window: self)
        view.wantsLayer = true
        view.layer = CALayer()
        surfaceLayer.contentsGravity = .resize
        surfaceLayer.magnificationFilter = .linear
        surfaceLayer.minificationFilter = .linear
        surfaceLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(surfaceLayer)
        contentView = view
        title = info.title.isEmpty ? info.appName : "\(info.appName) — \(info.title)"
    }

    static func level(for kind: WindowInfo.Kind) -> NSWindow.Level {
        switch kind {
        case .normal: return .normal
        case .panel: return .floating
        case .menu, .menuBar: return .popUpMenu
        }
    }

    var boundSurface: IOSurface? { surfaceLayer.contents as? IOSurface }

    override var canBecomeKey: Bool { info.kind != .menu }
    override var canBecomeMain: Bool { info.kind == .normal }

    func update(info: WindowInfo, frame: CGRect, contentsRect: CGRect, surface: IOSurface?) {
        self.info = info
        level = Self.level(for: info.kind)
        let t = info.title.isEmpty ? info.appName : "\(info.appName) — \(info.title)"
        if title != t { title = t }
        if self.frame != frame { setFrame(frame, display: false) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceLayer.frame = contentView?.bounds ?? .zero
        surfaceLayer.contentsScale = backingScaleFactor
        surfaceLayer.contentsRect = contentsRect
        if surfaceLayer.contents as AnyObject? !== surface { surfaceLayer.contents = surface }
        CATransaction.commit()
        if !isVisible { orderFront(nil) }
    }

    /// Tells Core Animation the IOSurface pixels changed.
    func contentsChanged(surface: IOSurface?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if surfaceLayer.contents as AnyObject? !== surface {
            // First frame after the window appeared, or the surface was reallocated (resize).
            surfaceLayer.contents = surface
        } else if surfaceLayer.responds(to: Selector(("setContentsChanged"))) {
            surfaceLayer.perform(Selector(("setContentsChanged")))
        } else {
            surfaceLayer.contents = nil
            surfaceLayer.contents = surface
        }
        CATransaction.commit()
    }

    override func becomeKey() {
        super.becomeKey()
        controller?.windowDidBecomeKey(info.id)
    }

    override func performClose(_ sender: Any?) { controller?.requestClose(info.id) }

    func requestExit() { controller?.onExit?() }

    func fileDrop(_ urls: [URL], atScreen point: NSPoint) { controller?.fileDrop(urls, atHost: point) }

    // MARK: Input

    fileprivate func pointer(_ event: NSEvent, kind: PointerEvent.Kind) {
        guard let controller else { return }
        let screenPoint = convertPoint(toScreen: event.locationInWindow)
        let g = controller.guestPoint(fromHostScreen: screenPoint)
        let button: PointerEvent.Button = event.buttonNumber == 0 ? .left : (event.buttonNumber == 1 ? .right : .other)
        var e = PointerEvent(kind: kind, button: button, clickCount: UInt8(clamping: max(event.clickCount, 1)),
                             x: Float(g.x), y: Float(g.y), modifiers: UInt64(event.modifierFlags.rawValue))
        if kind == .scroll {
            e.scrollDX = Float(event.scrollingDeltaX)
            e.scrollDY = Float(event.scrollingDeltaY)
            e.preciseScroll = event.hasPreciseScrollingDeltas
        }
        controller.send(.pointer(e))
    }

    fileprivate func key(_ event: NSEvent, down: Bool) {
        let text = event.type == .flagsChanged ? "" : (event.characters ?? "")
        controller?.send(.key(KeyEvent(keyCode: event.keyCode, down: down,
                                       modifiers: UInt64(event.modifierFlags.rawValue), text: text)))
    }

    fileprivate func forwardModifier(_ event: NSEvent) {
        // Modifier keys arrive as flagsChanged: derive down/up from whether the flag is now set.
        let flag: NSEvent.ModifierFlags
        switch Int(event.keyCode) {
        case 0x37, 0x36: flag = .command
        case 0x38, 0x3C: flag = .shift
        case 0x3A, 0x3D: flag = .option
        case 0x3B, 0x3E: flag = .control
        case 0x39: flag = .capsLock
        case 0x3F: flag = .function
        default: return
        }
        key(event, down: event.modifierFlags.contains(flag))
    }
}

/// Content view forwarding all input of a Coherence window to the guest.
final class CoherenceView: NSView {
    private unowned let owner: CoherenceWindow
    init(window: CoherenceWindow) {
        owner = window
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty, let w = window else { return false }
        owner.fileDrop(urls, atScreen: w.convertPoint(toScreen: sender.draggingLocation))
        return true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with e: NSEvent) { owner.pointer(e, kind: .move) }
    override func mouseDown(with e: NSEvent) { owner.pointer(e, kind: .down) }
    override func mouseUp(with e: NSEvent) { owner.pointer(e, kind: .up) }
    override func mouseDragged(with e: NSEvent) { owner.pointer(e, kind: .drag) }
    override func rightMouseDown(with e: NSEvent) { owner.pointer(e, kind: .down) }
    override func rightMouseUp(with e: NSEvent) { owner.pointer(e, kind: .up) }
    override func rightMouseDragged(with e: NSEvent) { owner.pointer(e, kind: .drag) }
    override func otherMouseDown(with e: NSEvent) { owner.pointer(e, kind: .down) }
    override func otherMouseUp(with e: NSEvent) { owner.pointer(e, kind: .up) }
    override func otherMouseDragged(with e: NSEvent) { owner.pointer(e, kind: .drag) }
    override func scrollWheel(with e: NSEvent) { owner.pointer(e, kind: .scroll) }
    override func keyDown(with e: NSEvent) { owner.key(e, down: true) }
    override func keyUp(with e: NSEvent) { owner.key(e, down: false) }
    override func flagsChanged(with e: NSEvent) { owner.forwardModifier(e) }
    // Deliver ⌘-shortcuts to the guest instead of the host menu.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard e.type == .keyDown, window?.isKeyWindow == true else { return false }
        // Control-Command-C leaves Coherence (same shortcut as entering it).
        if e.modifierFlags.contains([.control, .command]), e.charactersIgnoringModifiers?.lowercased() == "c" {
            owner.requestExit()
            return true
        }
        if e.modifierFlags.contains(.command), ["q", "w", "h", "m", "`"].contains(e.charactersIgnoringModifiers ?? "") {
            // Keep host-level window management shortcuts working, but still forward ⌘W/⌘Q to the guest app.
            if e.charactersIgnoringModifiers == "w" || e.charactersIgnoringModifiers == "q" {
                owner.key(e, down: true)
                owner.key(e, down: false)
                return true
            }
            return false
        }
        owner.key(e, down: true)
        owner.key(e, down: false)
        return true
    }
}
