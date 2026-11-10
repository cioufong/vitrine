import XCTest
import VitrineCore
@testable import VitrineVZ

/// VZ's SPICE agent port shares the clipboard both ways at all times, outside Vitrine's focus
/// gating. It is only for guests that have no Vitrine agent (macOS 15+ built-in support, Linux
/// spice-vdagent); once Vitrine has installed its agent the port is left out.
final class SpiceClipboardTests: XCTestCase {
    private func config(clipboard: Bool = true, agentInstalled: Bool? = nil, account: Bool = true) -> VMConfig {
        var c = VMConfig(name: "t", guestOS: .linux)
        c.features.clipboard = clipboard
        if account {
            c.account = .init(fullName: "A", username: "a")
            c.account?.agentInstalled = agentInstalled
        }
        return c
    }

    func testFreshBootWithoutAgentKeepsSpice() {
        XCTAssertTrue(ConfigurationBuilder.attachesSpiceClipboard(config: config(), restoring: false, savedMarker: nil))
        XCTAssertTrue(ConfigurationBuilder.attachesSpiceClipboard(config: config(account: false), restoring: false, savedMarker: nil),
                      "no record of a Vitrine agent: SPICE is the only clipboard there is")
        XCTAssertTrue(ConfigurationBuilder.attachesSpiceClipboard(config: config(agentInstalled: false), restoring: false, savedMarker: nil))
    }

    func testFreshBootWithVitrineAgentDropsSpice() {
        XCTAssertFalse(ConfigurationBuilder.attachesSpiceClipboard(config: config(agentInstalled: true), restoring: false, savedMarker: nil))
    }

    func testClipboardOffNeverAttachesSpice() {
        XCTAssertFalse(ConfigurationBuilder.attachesSpiceClipboard(config: config(clipboard: false), restoring: false, savedMarker: nil))
    }

    /// VZ restores a saved state only into a matching configuration: the port follows what the
    /// suspended run had, not what the configuration says now.
    func testRestoreFollowsTheSavedState() {
        XCTAssertTrue(ConfigurationBuilder.attachesSpiceClipboard(config: config(agentInstalled: true), restoring: true, savedMarker: true))
        XCTAssertFalse(ConfigurationBuilder.attachesSpiceClipboard(config: config(), restoring: true, savedMarker: false))
        XCTAssertTrue(ConfigurationBuilder.attachesSpiceClipboard(config: config(clipboard: false), restoring: true, savedMarker: true))
    }

    /// States saved before the marker existed had the port whenever clipboard sharing was on.
    func testLegacyStateWithoutMarker() {
        XCTAssertTrue(ConfigurationBuilder.attachesSpiceClipboard(config: config(agentInstalled: true), restoring: true, savedMarker: nil))
        XCTAssertFalse(ConfigurationBuilder.attachesSpiceClipboard(config: config(clipboard: false), restoring: true, savedMarker: nil))
    }

    func testMarkerRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = VMBundle(url: dir)
        XCTAssertNil(bundle.savedStateSpiceClipboard)
        try bundle.recordSavedStateSpiceClipboard(true)
        XCTAssertEqual(bundle.savedStateSpiceClipboard, true)
        try bundle.recordSavedStateSpiceClipboard(false)
        XCTAssertEqual(bundle.savedStateSpiceClipboard, false)
        bundle.discardSavedState()
        XCTAssertNil(bundle.savedStateSpiceClipboard, "discarding the saved state removes the marker too")
    }
}
