import AppKit
import XCTest
@testable import VitrineAgentHost

final class KeyNamesTests: XCTestCase {
    func testParsesCombinationsAndAliases() throws {
        XCTAssertEqual(try KeyNames.chord(named: "Ctrl+Alt+Delete"), ["ctrl", "alt", "delete"])
        XCTAssertEqual(try KeyNames.chord(named: "ctrl-alt-f1"), ["ctrl", "alt", "f1"])
        XCTAssertEqual(try KeyNames.chord(named: "cmd+space"), ["meta_l", "spc"])
        XCTAssertEqual(try KeyNames.chord(named: "ctrl+shift+t"), ["ctrl", "shift", "t"])
        XCTAssertEqual(try KeyNames.chord(named: "enter"), ["ret"])
        XCTAssertEqual(try KeyNames.chord(named: "a"), ["a"])
        XCTAssertThrowsError(try KeyNames.chord(named: "ctrl+bogus"))
    }

    func testEveryTypableCharacterHasAMacKeyCode() {
        // QEMUKeyboard's qcodes for US text must all map to Mac key codes for VZ guests.
        let names = "abcdefghijklmnopqrstuvwxyz0123456789".map(String.init)
            + ["spc", "ret", "tab", "minus", "equal", "bracket_left", "bracket_right", "backslash",
               "semicolon", "apostrophe", "comma", "dot", "slash", "grave_accent", "shift"]
        for n in names { XCTAssertNotNil(KeyNames.macKeyCodes[n], n) }
        XCTAssertEqual(Set(KeyNames.macKeyCodes.values).count, KeyNames.macKeyCodes.count, "no two names share a key code")
    }

    func testFlagOnlyEventsAreReplayedWithModifierKeys() {
        XCTAssertTrue(ModifierSync.isModifierKey(0x38))
        XCTAssertTrue(ModifierSync.isModifierKey(0x39), "Caps Lock")
        XCTAssertFalse(ModifierSync.isModifierKey(0), "key code 0 is A, not a modifier")
        // Shift state posted with key code 0, then "4" with Shift, then the release: Shift goes
        // down with its own key code and comes up after the key.
        var sync = ModifierSync()
        XCTAssertEqual(sync.align(to: [.shift]), [.init(keyCode: 0x38, down: true, flags: [.shift])])
        XCTAssertEqual(sync.align(to: [.shift]), [])
        XCTAssertEqual(sync.align(to: []), [.init(keyCode: 0x38, down: false, flags: [])])
    }

    func testOptionThatChangedNothingIsNotHeld() {
        var sync = ModifierSync()
        // An automation tool's plain "e" tagged with Option: not Alt+E.
        XCTAssertEqual(sync.wanted([.option], characters: "e", ignoringModifiers: "e"), [])
        // A real ⌥E is a dead key: no characters, so Option stays.
        XCTAssertEqual(sync.wanted([.option], characters: "", ignoringModifiers: "e"), [.option])
        XCTAssertEqual(sync.wanted([.option], characters: "å", ignoringModifiers: "a"), [.option])
        // Alt+Tab and Alt+arrows keep Option: whitespace and function keys aren't typed text.
        XCTAssertEqual(sync.wanted([.option], characters: "\t", ignoringModifiers: "\t"), [.option])
        XCTAssertEqual(sync.wanted([.option], characters: "\u{F702}", ignoringModifiers: "\u{F702}"), [.option])
        // Shift is never dropped, and an Option key held on the keyboard is always kept.
        XCTAssertEqual(sync.wanted([.shift, .option], characters: "E", ignoringModifiers: "E"), [.shift])
        sync.flagsChanged([.option])
        XCTAssertEqual(sync.wanted([.option], characters: "e", ignoringModifiers: "e"), [.option])
    }

    func testDeviceBitsFollowGenericModifiers() {
        // Held Shift without a device bit gains the left-hand one (0x02).
        XCTAssertEqual(DeviceModifierBits.reconciled([.shift]).rawValue & 0x06, 0x02)
        // A real right-hand Shift keeps its bit and gains no left one.
        let right = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x04)
        XCTAssertEqual(DeviceModifierBits.reconciled(right).rawValue & 0x06, 0x04)
        // After ⌘/⌥ swapping, the stale ⌘ bit goes and ⌥ gets its own.
        let swapped = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x08)
        let r = DeviceModifierBits.reconciled(swapped).rawValue
        XCTAssertEqual(r & 0x18, 0, "no Command device bits")
        XCTAssertEqual(r & 0x20, 0x20, "left Option device bit")
        XCTAssertEqual(DeviceModifierBits.reconciled([]).rawValue & 0x207F, 0)
        // A posted right-Shift press (key code 0x3C) without device bits gains the right-hand bit.
        XCTAssertEqual(DeviceModifierBits.reconciled([.shift], keyCode: 0x3C).rawValue & 0x06, 0x04)
        // A key code for another modifier doesn't pick Shift's hand.
        XCTAssertEqual(DeviceModifierBits.reconciled([.shift], keyCode: 0x3E).rawValue & 0x06, 0x02)
    }
}
