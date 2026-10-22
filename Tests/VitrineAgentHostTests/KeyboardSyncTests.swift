import AppKit
import XCTest
@testable import VitrineAgentHost

final class KeyboardSyncTests: XCTestCase {
    /// Automation types "A" as one key event with the Shift flag and no flagsChanged: Shift is
    /// pressed first and released after the key goes up.
    func testFlagOnlyShiftIsPressedAndReleasedAroundTheKey() {
        var s = ModifierSync()
        XCTAssertEqual(s.align(to: [.shift]), [.init(keyCode: 0x38, down: true, flags: [.shift])])
        XCTAssertEqual(s.align(to: [.shift]), [], "key-up with the same flags changes nothing")
        XCTAssertEqual(s.releaseSynthesized(), [.init(keyCode: 0x38, down: false, flags: [])])
        XCTAssertEqual(s.align(to: []), [], "a plain key afterwards needs nothing")
    }

    func testCommandShortcut() {
        var s = ModifierSync()
        let presses = s.align(to: [.command, .shift])
        XCTAssertEqual(presses.map(\.keyCode), [0x38, 0x37])
        XCTAssertEqual(presses.last?.flags, [.command, .shift])
        XCTAssertEqual(s.releaseSynthesized().map(\.keyCode), [0x38, 0x37])
        XCTAssertEqual(s.heldFlags, [])
    }

    /// A real keyboard reports modifiers itself; they are never pressed twice or released early.
    func testPhysicalModifiersAreLeftAlone() {
        var s = ModifierSync()
        s.flagsChanged([.shift])
        XCTAssertEqual(s.align(to: [.shift]), [])
        XCTAssertEqual(s.releaseSynthesized(), [])
        XCTAssertEqual(s.heldFlags, [.shift])
        s.flagsChanged([])
        XCTAssertEqual(s.heldFlags, [])
    }

    /// A synthesized modifier the next event no longer carries is released before that key.
    func testStaleSynthesizedModifierIsReleased() {
        var s = ModifierSync()
        _ = s.align(to: [.option])
        XCTAssertEqual(s.align(to: []), [.init(keyCode: 0x3A, down: false, flags: [])])
    }

    func testCapsLockAndFunctionFlagsAreIgnored() {
        var s = ModifierSync()
        XCTAssertEqual(s.align(to: [.capsLock, .function, .numericPad]), [])
    }

    func testCommandOptionSwap() {
        let (code, flags) = KeyRemap.swapCommandOption(keyCode: 0x37, flags: [.command, .shift])
        XCTAssertEqual(code, 0x3A)
        XCTAssertEqual(flags, [.option, .shift])
        XCTAssertEqual(KeyRemap.swapCommandOption(keyCode: 0x3D, flags: [.option]).0, 0x36)
        let plain = KeyRemap.swapCommandOption(keyCode: 0x00, flags: [.command])
        XCTAssertEqual(plain.0, 0x00)
        XCTAssertEqual(plain.1, [.option])
    }

    func testCommandOptionSwapIncludesBothDeviceSides() {
        for (input, expected): (UInt, UInt) in [(0x08, 0x20), (0x10, 0x40), (0x20, 0x08), (0x40, 0x10), (0x48, 0x30)] {
            let flags = NSEvent.ModifierFlags(rawValue: input).union([.command, .option, .shift])
            let (_, mapped) = KeyRemap.swapCommandOption(keyCode: 0x3D, flags: flags)
            XCTAssertEqual(mapped.rawValue & 0x78, expected)
            XCTAssertTrue(mapped.contains(.shift))
        }
    }

    func testSendKeyCombosAgreeBetweenBackends() {
        for combo in SendKeyCombo.allCases {
            XCTAssertEqual(combo.keyCodes.count, combo.qcodes.count, combo.title)
            // Modifiers come first so they are held when the final key goes down.
            let mods = combo.keyCodes.dropLast().map { SendKeyCombo.modifierFlag($0) }
            XCTAssertFalse(mods.contains { $0 == nil }, combo.title)
            XCTAssertNil(SendKeyCombo.modifierFlag(combo.keyCodes.last!), combo.title)
        }
    }
}
