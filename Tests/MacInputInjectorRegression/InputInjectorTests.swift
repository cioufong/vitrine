import XCTest
import CoreGraphics
import VitrineAgentProtocol
@testable import vitrine_agent

/// Real macOS CGEvents from the guest agent's injector, recorded at its post boundary so the test
/// never injects input into the host.
final class InputInjectorTests: XCTestCase {
    private var recorded: [CGEvent] = []
    private lazy var injector = InputInjector(post: { [unowned self] in recorded.append($0) })

    private func unicode(_ event: CGEvent) -> [UniChar] {
        var count = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &count, unicodeString: nil)
        var result = [UniChar](repeating: 0, count: count)
        if count > 0 { event.keyboardGetUnicodeString(maxStringLength: count, actualStringLength: &count, unicodeString: &result) }
        return result
    }

    private func keyCode(_ event: CGEvent?) -> Int64? { event?.getIntegerValueField(.keyboardEventKeycode) }

    func testSyntheticTextUsesAValidKeyCodeAndKeepsItsUnicode() throws {
        let fixture = "Vitrine fixture 繁體 ✓ 😀"
        injector.key(KeyEvent(keyCode: 0xffff, down: true, modifiers: 0, text: fixture))
        XCTAssertEqual(recorded.count, 1, "one event constructed at post boundary")
        let event = try XCTUnwrap(recorded.last)
        XCTAssertEqual(keyCode(event), 0, "synthetic sentinel maps to valid native keycode")
        XCTAssertEqual(unicode(event), Array(fixture.utf16), "synthetic Unicode and surrogate pair preserved")
        XCTAssertEqual(event.type, .keyDown, "synthetic down remains keyDown")

        injector.releaseAll()
        XCTAssertEqual(keyCode(recorded.last), 0, "disconnect releases normalized held key")
        XCTAssertEqual(recorded.last?.type, .keyUp, "disconnect constructs keyUp")

        injector.key(KeyEvent(keyCode: 0xffff, down: false, modifiers: 0, text: fixture))
        XCTAssertEqual(keyCode(recorded.last), 0, "synthetic keyUp maps to same valid keycode")
    }

    func testOrdinaryKeysAndShortcuts() throws {
        injector.key(KeyEvent(keyCode: 11, down: true, modifiers: 0, text: "b"))
        XCTAssertEqual(keyCode(recorded.last), 11, "ordinary physical keycode preserved")
        XCTAssertEqual(recorded.last.map(unicode), Array("b".utf16), "ordinary text preserved")

        injector.key(KeyEvent(keyCode: 8, down: true, modifiers: 1 << 20, text: "DO-NOT-INJECT"))
        let shortcut = try XCTUnwrap(recorded.last)
        XCTAssertEqual(keyCode(shortcut), 8, "shortcut physical code preserved")
        XCTAssertTrue(shortcut.flags.contains(.maskCommand), "shortcut Command flag preserved")
        XCTAssertNotEqual(unicode(shortcut), Array("DO-NOT-INJECT".utf16), "shortcut does not attach arbitrary text")
    }

    func testTeardownNeverPostsTheTextSentinel() {
        injector.key(KeyEvent(keyCode: 0xffff, down: true, modifiers: 0, text: "x"))
        injector.key(KeyEvent(keyCode: 11, down: true, modifiers: 0, text: "b"))
        injector.key(KeyEvent(keyCode: 8, down: true, modifiers: 1 << 20))
        let before = recorded.count
        injector.releaseAll()
        let released = recorded.dropFirst(before)
        XCTAssertEqual(Set(released.compactMap(keyCode)), [0, 11, 8], "every held key released")
        XCTAssertTrue(released.allSatisfy { keyCode($0) != 0xffff }, "teardown never posts invalid sentinel")
    }
}
