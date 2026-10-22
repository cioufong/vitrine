import Foundation
import VitrineCore

/// Key names shared by `vitrinectl keys`, the MCP server and both backends: QEMU qcodes (QMP
/// `send-key`) and the Mac virtual key codes a VZVirtualMachineView turns into USB HID keys.
public enum KeyNames {
    /// Mac virtual key code of each qcode on a US keyboard (Carbon kVK_* values).
    public static let macKeyCodes: [String: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08,
        "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12,
        "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "equal": 0x18, "9": 0x19, "7": 0x1A,
        "minus": 0x1B, "8": 0x1C, "0": 0x1D, "bracket_right": 0x1E, "o": 0x1F, "u": 0x20,
        "bracket_left": 0x21, "i": 0x22, "p": 0x23, "ret": 0x24, "l": 0x25, "j": 0x26, "apostrophe": 0x27,
        "k": 0x28, "semicolon": 0x29, "backslash": 0x2A, "comma": 0x2B, "slash": 0x2C, "n": 0x2D, "m": 0x2E,
        "dot": 0x2F, "tab": 0x30, "spc": 0x31, "grave_accent": 0x32, "backspace": 0x33, "esc": 0x35,
        "meta_r": 0x36, "meta_l": 0x37, "shift": 0x38, "caps_lock": 0x39, "alt": 0x3A, "ctrl": 0x3B,
        "shift_r": 0x3C, "alt_r": 0x3D, "ctrl_r": 0x3E, "f17": 0x40, "f18": 0x4F, "f19": 0x50, "f20": 0x5A,
        "f5": 0x60, "f6": 0x61, "f7": 0x62, "f3": 0x63, "f8": 0x64, "f9": 0x65, "f11": 0x67, "f13": 0x69,
        "f16": 0x6A, "f14": 0x6B, "f10": 0x6D, "f12": 0x6F, "f15": 0x71, "insert": 0x72, "home": 0x73,
        "pgup": 0x74, "delete": 0x75, "f4": 0x76, "end": 0x77, "f2": 0x78, "pgdn": 0x79, "f1": 0x7A,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
    ]

    static let aliases: [String: String] = [
        "control": "ctrl", "option": "alt", "opt": "alt", "cmd": "meta_l", "command": "meta_l",
        "win": "meta_l", "super": "meta_l", "meta": "meta_l", "enter": "ret", "return": "ret",
        "space": "spc", "escape": "esc", "del": "delete", "pageup": "pgup", "pagedown": "pgdn",
        "page_up": "pgup", "page_down": "pgdn", "bksp": "backspace",
    ]

    /// Parses a key combination: a Send Key title ("Ctrl+Alt+Delete", "ctrl-alt-delete") or key
    /// names joined by "+" ("ctrl+shift+t", "cmd+space", "f5"). Throws on names it doesn't know.
    public static func chord(named name: String) throws -> [String] {
        let lowered = name.lowercased().trimmingCharacters(in: .whitespaces)
        if let combo = SendKeyCombo.allCases.first(where: {
            [$0.title.lowercased(), $0.title.lowercased().replacingOccurrences(of: "+", with: "-")].contains(lowered)
        }) {
            return combo.qcodes
        }
        let separator: Character = lowered.contains("+") || lowered.count == 1 ? "+" : "-"
        let parts = lowered.split(separator: separator).map {
            let s = String($0).trimmingCharacters(in: .whitespaces)
            return aliases[s] ?? s
        }
        guard !parts.isEmpty else { throw VitrineError.invalidConfig("empty key combination") }
        for p in parts where macKeyCodes[p] == nil {
            throw VitrineError.invalidConfig("unknown key \"\(p)\" (use names like ctrl, alt, shift, cmd, ret, esc, tab, f1, a, 1, left)")
        }
        return parts
    }
}
