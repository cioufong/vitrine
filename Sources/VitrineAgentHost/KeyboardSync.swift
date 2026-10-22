import AppKit

/// Keeps the modifier keys a guest believes are held in step with the key events it receives.
///
/// A real keyboard reports each modifier with a `flagsChanged` event before the key it modifies.
/// Synthesized input (automation, remote control, accessibility tools) often sets the flags on the
/// key event alone, so a display view that tracks `flagsChanged` sends "a" instead of "A" and "s"
/// instead of ⌘S. Before each key event, `align(to:)` returns the modifier presses and releases that
/// make the guest's state match the event; modifiers it pressed this way are released again after
/// the key goes up. Modifiers the user physically holds are never touched.
public struct ModifierSync {
    /// The four modifiers this tracks, with the left-hand key used to press them.
    public static let modifiers: [(flag: NSEvent.ModifierFlags, keyCode: UInt16)] = [
        (.shift, 0x38), (.control, 0x3B), (.option, 0x3A), (.command, 0x37),
    ]
    static let relevant: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    /// Modifiers held according to real `flagsChanged` events.
    public private(set) var physical: NSEvent.ModifierFlags = []
    /// Modifiers pressed on the event's behalf.
    public private(set) var synthesized: NSEvent.ModifierFlags = []

    public init() {}

    /// Key codes of the modifier keys: ⌘, Shift, Caps Lock, ⌥, Control (both hands) and Fn.
    static let modifierKeyCodes: Set<UInt16> = [0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F]

    /// Whether a `flagsChanged` event names the modifier key that changed. Some automation tools
    /// post modifier state with key code 0, which Virtualization.framework ignores; such events
    /// are better replayed with `align(to:)`.
    public static func isModifierKey(_ keyCode: UInt16) -> Bool { modifierKeyCodes.contains(keyCode) }

    /// A real modifier change: it defines the held state from now on.
    public mutating func flagsChanged(_ flags: NSEvent.ModifierFlags) {
        physical = flags.intersection(Self.relevant)
        synthesized.subtract(physical)
    }

    /// One modifier press or release, with the held modifiers right after it (what a
    /// `flagsChanged` event for it carries).
    public struct Change: Equatable {
        public var keyCode: UInt16
        public var down: Bool
        public var flags: NSEvent.ModifierFlags
    }

    /// The modifiers a key event asks the guest to hold. Option that only came as a flag (not held
    /// on a keyboard) is dropped when it left a printable character unchanged: some automation
    /// tools tag plain letters with it, while a real ⌥ changes the character ("e" becomes a dead "´").
    public func wanted(_ flags: NSEvent.ModifierFlags, characters: String?, ignoringModifiers: String?) -> NSEvent.ModifierFlags {
        guard flags.contains(.option), !physical.contains(.option),
              let c = characters, !c.isEmpty, c == ignoringModifiers,
              !c.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespaces.contains($0)
                  || (0xF700...0xF8FF).contains($0.value) }) else { return flags }
        return flags.subtracting(.option)
    }

    /// Modifier key presses and releases needed before a key event carrying `flags`.
    public mutating func align(to flags: NSEvent.ModifierFlags) -> [Change] {
        let want = flags.intersection(Self.relevant)
        var out: [Change] = []
        for (flag, code) in Self.modifiers {
            let held = physical.contains(flag) || synthesized.contains(flag)
            if want.contains(flag) && !held {
                synthesized.insert(flag)
                out.append(Change(keyCode: code, down: true, flags: heldFlags))
            } else if !want.contains(flag) && synthesized.contains(flag) {
                synthesized.remove(flag)
                out.append(Change(keyCode: code, down: false, flags: heldFlags))
            }
        }
        return out
    }

    /// Releases the modifiers pressed on a key's behalf (after its key-up).
    public mutating func releaseSynthesized() -> [Change] {
        var out: [Change] = []
        for (flag, code) in Self.modifiers where synthesized.contains(flag) {
            synthesized.remove(flag)
            out.append(Change(keyCode: code, down: false, flags: heldFlags))
        }
        return out
    }

    /// Modifiers the guest currently has held.
    public var heldFlags: NSEvent.ModifierFlags { physical.union(synthesized) }
}

/// Device-dependent modifier bits (IOLLEvent.h NX_DEVICE*KEYMASK). A real keyboard sets them next
/// to the generic flags, one per physical key held, and Virtualization.framework reads them to tell
/// whether a `flagsChanged` event pressed or released its key: without them a synthesized Shift
/// counts as released and the guest types "4" for "$".
public enum DeviceModifierBits {
    /// (generic flag, left-hand bit, right-hand bit)
    static let keys: [(flag: NSEvent.ModifierFlags, left: UInt, right: UInt)] = [
        (.control, 0x01, 0x2000), (.shift, 0x02, 0x04), (.command, 0x08, 0x10), (.option, 0x20, 0x40),
    ]

    /// Right-hand modifier key codes (Shift, Control, Option, Command).
    static let rightHand: Set<UInt16> = [0x3C, 0x3E, 0x3D, 0x36]

    /// `flags` with device bits that agree with its generic modifiers: a held modifier without a
    /// bit for either hand gets the left-hand one (the right-hand one when `keyCode` is that
    /// modifier's right-hand key), and released modifiers lose theirs.
    public static func reconciled(_ flags: NSEvent.ModifierFlags, keyCode: UInt16? = nil) -> NSEvent.ModifierFlags {
        var raw = flags.rawValue
        for k in keys {
            if flags.contains(k.flag) {
                if raw & (k.left | k.right) == 0 {
                    let right = keyCode.map { rightHand.contains($0) && SendKeyCombo.modifierFlag($0) == k.flag } ?? false
                    raw |= right ? k.right : k.left
                }
            } else {
                raw &= ~(k.left | k.right)
            }
        }
        return NSEvent.ModifierFlags(rawValue: raw)
    }
}

/// Mac virtual key codes for ⌘/⌥ (left and right).
public enum KeyRemap {
    static let swaps: [UInt16: UInt16] = [0x37: 0x3A, 0x3A: 0x37, 0x36: 0x3D, 0x3D: 0x36]

    /// Swaps Command and Option (key codes and flags), for guests whose layout puts Alt where the
    /// Mac has Command (Windows, Linux).
    public static func swapCommandOption(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> (UInt16, NSEvent.ModifierFlags) {
        var f = flags
        let cmd = flags.contains(.command), opt = flags.contains(.option)
        f.remove([.command, .option])
        if cmd { f.insert(.option) }
        if opt { f.insert(.command) }
        var raw = f.rawValue & ~UInt(0x78)
        raw |= (flags.rawValue & 0x18) << 2
        raw |= (flags.rawValue & 0x60) >> 2
        return (swaps[keyCode] ?? keyCode, NSEvent.ModifierFlags(rawValue: raw))
    }
}

/// Key combinations offered in Actions ▸ Send Key, as Mac virtual key codes pressed in order and
/// released in reverse.
public enum SendKeyCombo: String, CaseIterable, Identifiable, Sendable {
    case ctrlAltDelete, ctrlAltBackspace, ctrlAltF1, ctrlAltF2, ctrlAltF3, ctrlAltF7, ctrlEsc, altTab, altF4

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ctrlAltDelete: "Ctrl+Alt+Delete"
        case .ctrlAltBackspace: "Ctrl+Alt+Backspace"
        case .ctrlAltF1: "Ctrl+Alt+F1"
        case .ctrlAltF2: "Ctrl+Alt+F2"
        case .ctrlAltF3: "Ctrl+Alt+F3"
        case .ctrlAltF7: "Ctrl+Alt+F7"
        case .ctrlEsc: "Ctrl+Esc"
        case .altTab: "Alt+Tab"
        case .altF4: "Alt+F4"
        }
    }

    /// Mac key codes: Control 0x3B, Option (Alt) 0x3A, forward Delete 0x75, Delete (Backspace)
    /// 0x33, F1 0x7A, F2 0x78, F3 0x63, F7 0x62, Esc 0x35, Tab 0x30, F4 0x76.
    public var keyCodes: [UInt16] {
        switch self {
        case .ctrlAltDelete: [0x3B, 0x3A, 0x75]
        case .ctrlAltBackspace: [0x3B, 0x3A, 0x33]
        case .ctrlAltF1: [0x3B, 0x3A, 0x7A]
        case .ctrlAltF2: [0x3B, 0x3A, 0x78]
        case .ctrlAltF3: [0x3B, 0x3A, 0x63]
        case .ctrlAltF7: [0x3B, 0x3A, 0x62]
        case .ctrlEsc: [0x3B, 0x35]
        case .altTab: [0x3A, 0x30]
        case .altF4: [0x3A, 0x76]
        }
    }

    /// The same keys as QEMU key codes (QMP `send-key`).
    public var qcodes: [String] {
        switch self {
        case .ctrlAltDelete: ["ctrl", "alt", "delete"]
        case .ctrlAltBackspace: ["ctrl", "alt", "backspace"]
        case .ctrlAltF1: ["ctrl", "alt", "f1"]
        case .ctrlAltF2: ["ctrl", "alt", "f2"]
        case .ctrlAltF3: ["ctrl", "alt", "f3"]
        case .ctrlAltF7: ["ctrl", "alt", "f7"]
        case .ctrlEsc: ["ctrl", "esc"]
        case .altTab: ["alt", "tab"]
        case .altF4: ["alt", "f4"]
        }
    }

    /// The modifier flag a key code stands for, if it is a modifier.
    public static func modifierFlag(_ keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 0x38, 0x3C: .shift
        case 0x3B, 0x3E: .control
        case 0x3A, 0x3D: .option
        case 0x37, 0x36: .command
        default: nil
        }
    }
}
