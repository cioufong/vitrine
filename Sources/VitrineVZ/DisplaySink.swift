import AppKit
import Virtualization

/// A tiny, practically invisible window that keeps a VZVirtualMachineView presenting the guest display.
///
/// Virtualization.framework only lets a display be reconfigured while a view is actively presenting
/// it ("Display does not support reconfiguration at this time" otherwise). A fully transparent window
/// isn't composited and doesn't count, so the sink is an opaque 4×4 window parked in a screen
/// corner at desktop level (below every app window). Its size doesn't matter: with automatic
/// reconfiguration off, the guest keeps the size we request.
@MainActor
public final class DisplaySink {
    private let window: NSWindow
    public let view: GuestDisplayView

    public init(virtualMachine: VZVirtualMachine, screen: NSScreen) {
        view = GuestDisplayView()
        view.automaticallyReconfiguresDisplay = false
        view.capturesSystemKeys = false
        view.virtualMachine = virtualMachine
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: 4, height: 4)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.stationary, .ignoresCycle, .canJoinAllSpaces]
        window.contentView = view
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
    }

    /// Lets the view cover `size` points although the window stays 4×4, so pointer automation can
    /// address every guest pixel (`GuestDisplayView.pointer`).
    public func setViewSize(_ size: CGSize) {
        guard view.frame.size != size else { return }
        window.contentView = nil
        view.frame = NSRect(origin: .zero, size: size)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 4, height: 4))
        container.addSubview(view)
        window.contentView = container
    }

    public func close() {
        view.virtualMachine = nil
        window.orderOut(nil)
    }
}
