import XCTest
@testable import VitrineCore

final class SleepGuardTests: XCTestCase {
    override func tearDown() {
        VitrinePreferences.keepAwakeWhileRunning = true
        super.tearDown()
    }

    func testHeldWhileAnyVMRunsAndReleasedWithTheLast() {
        let g = SleepGuard()
        VitrinePreferences.keepAwakeWhileRunning = true
        g.set("a", running: true)
        g.set("b", running: true)
        XCTAssertTrue(g.isHolding)
        g.set("a", running: false)
        XCTAssertTrue(g.isHolding)
        g.set("b", running: false)
        XCTAssertFalse(g.isHolding)
    }

    func testTurningThePreferenceOffReleasesIt() {
        let g = SleepGuard()
        VitrinePreferences.keepAwakeWhileRunning = true
        g.set("a", running: true)
        XCTAssertTrue(g.isHolding)
        VitrinePreferences.keepAwakeWhileRunning = false
        g.preferenceChanged()
        XCTAssertFalse(g.isHolding)
        g.set("b", running: true) // new VMs don't take it either while off
        XCTAssertFalse(g.isHolding)
    }
}
