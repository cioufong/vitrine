import XCTest
import AppKit
@testable import VitrineAgentHost
@testable import VitrineAgentProtocol

final class CoherenceWindowLevelTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @MainActor func testOrdinaryMenusFloat() {
        let menu = CGRect(x: 100, y: 100, width: 240, height: 400)
        XCTAssertEqual(CoherenceWindow.level(for: .menu, frame: menu, screen: screen), .popUpMenu)
        XCTAssertEqual(CoherenceWindow.level(for: .menuBar, frame: CGRect(x: 0, y: 958, width: 1512, height: 24), screen: screen), .popUpMenu)
        XCTAssertEqual(CoherenceWindow.level(for: .normal, frame: menu, screen: screen), .normal)
    }

    /// A guest dialog can sit behind another app's window in the guest; floating it on the Mac
    /// showed that window's pixels inside the dialog's frame. Panels follow the guest's stacking.
    @MainActor func testPanelsAreStackedLikeWindows() {
        let dialog = CGRect(x: 400, y: 300, width: 560, height: 290)
        XCTAssertEqual(CoherenceWindow.level(for: .panel, frame: dialog, screen: screen), .normal)
        XCTAssertFalse(CoherenceWindow.hidesOnDeactivate(for: CoherenceWindow.level(for: .panel, frame: dialog, screen: screen)))
    }

    /// The guest says what kind a window is. A "menu" covering the screen would sit above every
    /// app on the Mac (a fake password prompt, say), so oversized ones stay at the normal level.
    @MainActor func testOversizedGuestOverlaysAreNotRaised() {
        XCTAssertEqual(CoherenceWindow.level(for: .menu, frame: screen, screen: screen), .normal)
        XCTAssertEqual(CoherenceWindow.level(for: .menuBar, frame: screen.insetBy(dx: 100, dy: 100), screen: screen), .normal)
        XCTAssertEqual(CoherenceWindow.level(for: .panel, frame: screen, screen: screen), .normal)
    }

    /// Raised windows disappear when Vitrine is not the frontmost app, like the Mac's own menus.
    @MainActor func testRaisedWindowsHideWhenVitrineIsInactive() {
        XCTAssertTrue(CoherenceWindow.hidesOnDeactivate(for: .popUpMenu))
        XCTAssertTrue(CoherenceWindow.hidesOnDeactivate(for: .floating))
        XCTAssertFalse(CoherenceWindow.hidesOnDeactivate(for: .normal))
    }
}
