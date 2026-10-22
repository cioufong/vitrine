import XCTest
@testable import VitrineQEMU

final class QEMUExitTests: XCTestCase {
    func testCleanExitIsGuestPowerOff() {
        let exit = QEMUExit(status: 0, output: "", uncaughtSignal: false)
        XCTAssertTrue(exit.isGuestPowerOff)
        XCTAssertFalse(exit.killedByHost)
    }

    func testSignalLineMeansHostKill() {
        let out = "qemu-system-aarch64: terminating on signal 15 from pid 24056 (<unknown process>)\n"
        let exit = QEMUExit(status: 0, output: out, uncaughtSignal: false)
        XCTAssertTrue(exit.killedByHost)
        XCTAssertFalse(exit.isGuestPowerOff)
    }

    func testSIGKILLIsHostKill() {
        let exit = QEMUExit(status: 9, output: "", uncaughtSignal: true)
        XCTAssertTrue(exit.killedByHost)
        XCTAssertFalse(exit.isGuestPowerOff)
    }

    /// Guards against QEMU changing the message: SIGTERM a real QEMU and check its own output.
    func testRealQEMUReportsSIGTERM() throws {
        let env: QEMUEnvironment
        do { env = try QEMUEnvironment.detect() } catch { throw XCTSkip("QEMU not installed") }
        let p = Process()
        p.executableURL = env.system(.aarch64)
        p.arguments = ["-machine", "none", "-nographic", "-monitor", "none", "-serial", "none"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        Thread.sleep(forTimeInterval: 0.5)
        p.terminate()
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let exit = QEMUExit(status: p.terminationStatus, output: out,
                            uncaughtSignal: p.terminationReason == .uncaughtSignal)
        XCTAssertEqual(exit.status, 0, out)
        XCTAssertTrue(exit.killedByHost, out)
    }
}
