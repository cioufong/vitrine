import XCTest
import VitrineCore
@testable import VitrineQEMU

final class WindowsSetupFinalizationTests: XCTestCase {
    private func installingWindows(agentSeen: Bool?) -> VMConfig {
        var config = VMConfig(name: "setup", guestOS: .windows)
        config.backend = .qemu
        config.installMedia = "/windows.iso"
        config.extraMedia = ["seed.iso"]
        config.windowsSetupAgentSeen = agentSeen
        return config
    }

    func testPhaseFollowsMediaAndAgent() {
        var config = installingWindows(agentSeen: nil)
        XCTAssertEqual(WindowsSetup(config), .installing(offline: false))
        config.windowsSetupAgentSeen = true
        XCTAssertEqual(WindowsSetup(config), .agentSeen)
        config.installMedia = nil
        config.extraMedia = nil
        XCTAssertEqual(WindowsSetup(config), .inactive)
    }

    func testPrematureGuestPowerOffDoesNotFinalizeUnseenSetup() {
        let exit = QEMUExit(status: 0, output: "", uncaughtSignal: false)
        for seen: Bool? in [nil, false] {
            XCTAssertFalse(WindowsSetup(installingWindows(agentSeen: seen)).isFinished(by: exit, isRunning: true),
                           "a clean WinPE/Setup shutdown with agentSeen=\(String(describing: seen)) must retain installer media")
        }
    }

    func testCompletedSetupFinalizesOnlyWhileRunning() {
        let exit = QEMUExit(status: 0, output: "", uncaughtSignal: false)
        let config = installingWindows(agentSeen: true)
        XCTAssertTrue(WindowsSetup(config).isFinished(by: exit, isRunning: true))
        XCTAssertFalse(WindowsSetup(config).isFinished(by: exit, isRunning: false),
                       "host stop, pause, and suspend must not auto-restart a guest")
    }

    func testHostTerminationAndCrashDoNotFinalizeCompletedSetup() {
        let config = installingWindows(agentSeen: true)
        let exits = [
            QEMUExit(status: 0, output: "qemu-system-aarch64: terminating on signal 15 from pid 42\n", uncaughtSignal: false),
            QEMUExit(status: 9, output: "", uncaughtSignal: true),
            QEMUExit(status: 1, output: "backend failed", uncaughtSignal: false),
        ]
        for exit in exits {
            XCTAssertFalse(WindowsSetup(config).isFinished(by: exit, isRunning: true))
        }
    }

    func testOtherGuestsAndDetachedMediaDoNotFinalizeWindowsSetup() {
        let exit = QEMUExit(status: 0, output: "", uncaughtSignal: false)
        for os in [VMConfig.GuestOS.macOS, .linux] {
            var config = installingWindows(agentSeen: true)
            config.guestOS = os
            XCTAssertFalse(WindowsSetup(config).isFinished(by: exit, isRunning: true))
        }
        var config = installingWindows(agentSeen: true)
        config.installMedia = nil
        config.extraMedia = nil
        XCTAssertFalse(WindowsSetup(config).isFinished(by: exit, isRunning: true))
    }
}
