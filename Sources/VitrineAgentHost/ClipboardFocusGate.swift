import Foundation

/// When a VM's clipboard may follow the Mac's (see `VirtualMachineController.setClipboardFocus`).
///
/// - Mac → guest: only while the VM is focused (its display window or one of its seamless
///   windows is key and Vitrine is the active app). A VM in the background never sees what is
///   copied on the Mac, such as a password.
/// - Guest → Mac: while focused, or for `grace` seconds after losing focus, so copying in the
///   guest and then switching to a Mac app to paste still works. Otherwise a background guest
///   could replace what the user copied on the Mac (a wallet address, say).
///
/// Starts unfocused. Pure value type: the caller supplies the clock.
public struct ClipboardFocusGate: Sendable {
    public static let defaultGrace: TimeInterval = 2

    public let grace: TimeInterval
    public private(set) var isFocused = false
    private var lostFocusAt: Date?

    public init(grace: TimeInterval = ClipboardFocusGate.defaultGrace) {
        self.grace = grace
    }

    /// Records a focus change; returns whether focus actually changed.
    @discardableResult
    public mutating func setFocused(_ focused: Bool, at now: Date) -> Bool {
        guard focused != isFocused else { return false }
        isFocused = focused
        lostFocusAt = focused ? nil : now
        return true
    }

    /// Whether the Mac clipboard may be sent to the guest.
    public var allowsSending: Bool { isFocused }

    /// Whether clipboard content arriving from the guest may be written to the Mac clipboard.
    public func acceptsGuestClipboard(at now: Date) -> Bool {
        if isFocused { return true }
        guard let lost = lostFocusAt else { return false }
        let elapsed = now.timeIntervalSince(lost)
        return elapsed >= 0 && elapsed <= grace
    }
}
