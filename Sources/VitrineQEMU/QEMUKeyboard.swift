import Foundation
import VitrineCore

/// Types text into a QEMU guest through QMP `send-key`, as a US keyboard would: each character
/// becomes one key chord (with Shift where needed). Characters a US keyboard can't type are refused.
public enum QEMUKeyboard {
    static let plain: [Character: String] = {
        var m: [Character: String] = [:]
        for c in "abcdefghijklmnopqrstuvwxyz" { m[c] = String(c) }
        for c in "0123456789" { m[c] = String(c) }
        let named: [Character: String] = [
            " ": "spc", "\n": "ret", "\t": "tab", "-": "minus", "=": "equal", "[": "bracket_left",
            "]": "bracket_right", "\\": "backslash", ";": "semicolon", "'": "apostrophe", ",": "comma",
            ".": "dot", "/": "slash", "`": "grave_accent",
        ]
        m.merge(named) { $1 }
        return m
    }()

    static let shifted: [Character: String] = {
        var m: [Character: String] = [:]
        for c in "abcdefghijklmnopqrstuvwxyz" { m[Character(c.uppercased())] = String(c) }
        let named: [Character: String] = [
            "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9",
            ")": "0", "_": "minus", "+": "equal", "{": "bracket_left", "}": "bracket_right", "|": "backslash",
            ":": "semicolon", "\"": "apostrophe", "<": "comma", ">": "dot", "?": "slash", "~": "grave_accent",
        ]
        m.merge(named) { $1 }
        return m
    }()

    /// The key chord (QEMU qcodes) that types `c`, or nil if a US keyboard has no key for it.
    public static func chord(for c: Character) -> [String]? {
        if let k = plain[c] { return [k] }
        if let k = shifted[c] { return ["shift", k] }
        return nil
    }

    /// Chords for every character of `text`; throws on the first one that can't be typed.
    public static func chords(for text: String) throws -> [[String]] {
        try text.map { c in
            guard let chord = chord(for: c) else {
                throw VitrineError.unsupported("can't type \"\(c)\" through the emulated US keyboard")
            }
            return chord
        }
    }

    /// Sends chords one at a time over `qmp` (each is pressed together and released).
    public static func send(_ chords: [[String]], over qmp: QMPClient) throws {
        for chord in chords {
            _ = try qmp.execute("send-key", arguments: ["keys": chord.map { ["type": "qcode", "data": $0] }])
        }
    }
}
