import XCTest
@testable import VitrineAgentProtocol
@testable import VitrineAgentHost

/// The keepalive must only give up on a guest that stopped answering, not on one the host stopped
/// asking: a modal panel, an open menu or host sleep starves the ping timer, and the first tick
/// afterwards used to compare a stale pong time and drop a healthy agent.
final class KeepaliveTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        // NSApplication makes its tracking and modal modes common modes; a test process has no
        // NSApplication, so do the same here.
        for mode in [RunLoop.Mode.eventTracking, .modalPanel] {
            CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(mode.rawValue as CFString))
        }
    }

    private func connectedSession(pongTimeout: TimeInterval, pingInterval: TimeInterval, answerPings: Bool = true,
                                  onPing: @escaping () -> Void = {}) throws -> (AgentSession, AgentChannel) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let guest = AgentChannel(fileDescriptor: fds[1])
        guest.start(callbackQueue: .main, onMessage: { message in
            switch message {
            case .hello: guest.send(.hello(Hello(role: "guest", os: "test", agentVersion: "t", capabilities: [])))
            case .ping(let n):
                onPing()
                if answerPings { guest.send(.pong(n)) }
            default: break
            }
        }, onClose: { _ in })
        let session = AgentSession(channel: AgentChannel(fileDescriptor: fds[0]), pongTimeout: pongTimeout,
                                   frameQueue: DispatchQueue(label: "test.keepalive.frames"),
                                   maxPendingFrameBytes: 1 << 20, maxPendingFrameCount: 16, pingInterval: pingInterval)
        let ready = expectation(description: "handshake")
        session.onStateChange = { if case .ready = $0 { ready.fulfill() } }
        session.start()
        wait(for: [ready], timeout: 3)
        session.onStateChange = nil
        return (session, guest)
    }

    /// NSOpenPanel.runModal / NSAlert.runModal / menu tracking run the main run loop in a mode other
    /// than .default for as long as they're up.
    func testAModalRunLoopModeDoesNotDropAHealthyAgent() throws {
        var pings = 0
        let (session, guest) = try connectedSession(pongTimeout: 0.5, pingInterval: 0.1, onPing: { pings += 1 })
        defer { session.close(); guest.close() }
        // A run loop mode with no sources returns at once; a modal session always has some.
        let keepModeAlive = Timer(timeInterval: 60, repeats: false) { _ in }
        RunLoop.main.add(keepModeAlive, forMode: .eventTracking)
        defer { keepModeAlive.invalidate() }
        let deadline = Date().addingTimeInterval(1.2)
        let before = pings
        while Date() < deadline { RunLoop.main.run(mode: .eventTracking, before: deadline) }
        XCTAssertGreaterThan(pings - before, 3, "keepalive must keep pinging while a modal mode runs")
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(session.isReady, "dropped after a modal: \(session.state)")
    }

    /// Host sleep, or a main thread blocked for a while: the timer simply didn't run.
    func testAStarvedTimerDoesNotDropAHealthyAgent() throws {
        let (session, guest) = try connectedSession(pongTimeout: 0.5, pingInterval: 0.1)
        defer { session.close(); guest.close() }
        Thread.sleep(forTimeInterval: 1.2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(session.isReady, "dropped after a stall: \(session.state)")
    }

    func testASilentGuestIsStillGivenUp() throws {
        let (session, guest) = try connectedSession(pongTimeout: 0.5, pingInterval: 0.1, answerPings: false)
        defer { session.close(); guest.close() }
        let closed = expectation(description: "closed")
        session.onStateChange = { if case .closed = $0 { closed.fulfill() } }
        wait(for: [closed], timeout: 3)
    }

    // MARK: Decision

    private func action(now: TimeInterval, lastTick: TimeInterval?, lastPong: TimeInterval) -> AgentSession.KeepaliveAction {
        AgentSession.keepaliveAction(now: now, lastTick: lastTick, lastPong: lastPong, interval: 2, pongTimeout: 10)
    }

    func testPingsWhileTheGuestAnswers() {
        XCTAssertEqual(action(now: 100, lastTick: 98, lastPong: 99), .ping)
        XCTAssertEqual(action(now: 100, lastTick: nil, lastPong: 99), .ping, "first tick")
        XCTAssertEqual(action(now: 100, lastTick: 98, lastPong: 90), .ping, "exactly at the timeout")
    }

    func testGivesUpWhenPingsWentOutButNoPongCame() {
        XCTAssertEqual(action(now: 100, lastTick: 98, lastPong: 89), .giveUp)
        XCTAssertEqual(action(now: 100, lastTick: 96.5, lastPong: 80), .giveUp, "a late tick is not a stall")
        XCTAssertEqual(action(now: 100, lastTick: nil, lastPong: 80), .giveUp)
    }

    func testAStarvedTimerRestartsTheTimeoutInsteadOfGivingUp() {
        // A modal panel or sleep held the timer for 60 s: the pong is stale because nobody asked.
        XCTAssertEqual(action(now: 100, lastTick: 40, lastPong: 39), .restartTimeout)
        XCTAssertEqual(action(now: 100, lastTick: 95.9, lastPong: 0), .restartTimeout, "just over two intervals")
    }

    func testAfterRestartingAGuestThatStaysSilentIsGivenUp() {
        // Restart at t=100 (lastPong := 100), then regular ticks with no pong.
        var lastTick: TimeInterval = 100
        var t: TimeInterval = 100
        var result = AgentSession.KeepaliveAction.ping
        while result == .ping && t < 200 {
            t += 2
            result = action(now: t, lastTick: lastTick, lastPong: 100)
            lastTick = t
        }
        XCTAssertEqual(result, .giveUp)
        XCTAssertEqual(t, 112)
    }
}
