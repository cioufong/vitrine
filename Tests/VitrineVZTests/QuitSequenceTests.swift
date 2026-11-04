import XCTest
@testable import VitrineVZ

/// Quitting suspends every VM. A VM that can't be suspended, or doesn't shut down in time, is only
/// shut down or forced off after the user agreed, and the user can keep Vitrine open instead.
@MainActor
final class QuitSequenceTests: XCTestCase {
    final class FakeVM: QuitTarget {
        let name: String
        var shutsDownOnQuit = false
        var isDisposable = false
        var suspendError: Error?
        var shutsDown = true
        var events: [String] = []
        init(_ name: String) { self.name = name }
        func suspend() async throws {
            events.append("suspend")
            if let suspendError { throw suspendError }
        }
        func shutDown(timeout: TimeInterval) async -> Bool { events.append("shutDown"); return shutsDown }
        func forceStop() async { events.append("forceStop") }
        func note(_ line: String) { events.append("note") }
    }
    struct Failure: LocalizedError { var errorDescription: String? { "disk full" } }

    func testSuspendsWithoutAsking() async {
        let a = FakeVM("a")
        var asked = 0
        let quit = await QuitSequence.run([a]) { _ in asked += 1; return true }
        XCTAssertTrue(quit)
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(a.events, ["suspend"])
    }

    func testFailedSuspendAsksBeforeShuttingDown() async {
        let a = FakeVM("a"), b = FakeVM("b")
        a.suspendError = Failure()
        var questions: [QuitQuestion] = []
        let quit = await QuitSequence.run([a, b]) { questions.append($0); return true }
        XCTAssertTrue(quit)
        XCTAssertEqual(questions, [.suspendFailed([.init(name: "a", reason: "disk full")])])
        XCTAssertEqual(a.events, ["suspend", "shutDown"])
        XCTAssertEqual(b.events, ["suspend"])
    }

    func testKeepingVitrineOpenLeavesTheVMRunning() async {
        let a = FakeVM("a")
        a.suspendError = Failure()
        let quit = await QuitSequence.run([a]) { _ in false }
        XCTAssertFalse(quit)
        XCTAssertEqual(a.events, ["suspend"])
    }

    func testForcesOffOnlyAfterAskingAgain() async {
        let a = FakeVM("a")
        a.suspendError = Failure()
        a.shutsDown = false
        var questions: [QuitQuestion] = []
        var quit = await QuitSequence.run([a]) { questions.append($0); return true }
        XCTAssertTrue(quit)
        XCTAssertEqual(questions.last, .didNotShutDown(["a"]))
        XCTAssertEqual(a.events, ["suspend", "shutDown", "note", "forceStop"])

        let b = FakeVM("b")
        b.suspendError = Failure()
        b.shutsDown = false
        quit = await QuitSequence.run([b]) { if case .didNotShutDown = $0 { return false }; return true }
        XCTAssertFalse(quit)
        XCTAssertFalse(b.events.contains("forceStop"))
    }

    func testPlannedShutdownsAskOnlyWhenTheyHang() async {
        let drive = FakeVM("drive"), scratch = FakeVM("scratch")
        drive.shutsDownOnQuit = true
        drive.shutsDown = false
        scratch.shutsDownOnQuit = true
        scratch.isDisposable = true
        scratch.shutsDown = false
        var questions: [QuitQuestion] = []
        let quit = await QuitSequence.run([drive, scratch]) { questions.append($0); return true }
        XCTAssertTrue(quit)
        // A disposable VM loses nothing when forced off: no question for it.
        XCTAssertEqual(questions, [.didNotShutDown(["drive"])])
        XCTAssertEqual(drive.events, ["shutDown", "note", "forceStop"])
        XCTAssertEqual(scratch.events, ["shutDown", "note", "forceStop"])
    }
}
