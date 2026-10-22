import XCTest
@testable import VitrineAgentProtocol
@testable import VitrineAgentHost

final class FrameBacklogTests: XCTestCase {
    private func connectedSession(queue: DispatchQueue, bytes: Int = 1024, count: Int = 16) throws -> (AgentSession, AgentChannel) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let guest = AgentChannel(fileDescriptor: fds[1])
        guest.start(callbackQueue: .main, onMessage: { message in
            if case .hello = message {
                guest.send(.hello(Hello(role: "guest", os: "test", agentVersion: "t", capabilities: [])))
            }
        }, onClose: { _ in })
        let session = AgentSession(channel: AgentChannel(fileDescriptor: fds[0]), frameQueue: queue,
                                   maxPendingFrameBytes: bytes, maxPendingFrameCount: count)
        let ready = expectation(description: "handshake")
        session.onStateChange = { if case .ready = $0 { ready.fulfill() } }
        session.start()
        wait(for: [ready], timeout: 3)
        XCTAssertTrue(session.isReady)
        session.onStateChange = nil
        return (session, guest)
    }

    private func frame(_ value: UInt8 = 1, valid: Bool = true) -> AgentMessage {
        .frame(FrameUpdate(surfaceWidth: 1, surfaceHeight: 1, x: 0, y: 0, width: 1, height: 1,
                           encoding: valid ? .raw : .lz4, data: Data(repeating: value, count: valid ? 4 : 3)))
    }

    private func overflow(bytes: Int, count: Int) throws {
        let queue = DispatchQueue(label: "test.frames.blocked")
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        defer { gate.signal(); queue.sync {} }
        let (session, guest) = try connectedSession(queue: queue, bytes: bytes, count: count)
        defer { session.close(); guest.close() }
        let closed = expectation(description: "frame backlog closes connection")
        var closeReason: String?
        session.onStateChange = { if case .closed(let reason) = $0 { closeReason = reason; closed.fulfill() } }
        guest.send(frame(1)); guest.send(frame(2)); guest.send(frame(3))
        wait(for: [closed], timeout: 2)
        XCTAssertTrue(closeReason?.contains("frame backlog") == true, "\(String(describing: closeReason))")
        gate.signal()
        queue.sync {}
        XCTAssertEqual(session.framebuffer.generation, 0, "queued updates must be cancelled after close")
    }

    func testByteBudgetClosesFloodWhileDecoderIsBlocked() throws { try overflow(bytes: 8, count: 16) }
    func testCountBudgetClosesTinyFrameFlood() throws { try overflow(bytes: 1024, count: 2) }

    func testCloseCancelsQueuedFramesAndCallbacks() throws {
        let queue = DispatchQueue(label: "test.frames.close")
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        defer { gate.signal(); queue.sync {} }
        let (session, guest) = try connectedSession(queue: queue)
        defer { session.close(); guest.close() }
        let admitted = expectation(description: "control message behind frame received")
        session.onWindowsChanged = { _ in admitted.fulfill() }
        var frameCallbacks = 0
        session.onFrame = { _ in frameCallbacks += 1 }
        guest.send(frame()); guest.send(.windowList(WindowList(windows: [])))
        wait(for: [admitted], timeout: 2)
        session.close()
        gate.signal(); queue.sync {}
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(session.framebuffer.generation, 0)
        XCTAssertEqual(frameCallbacks, 0)
    }

    func testAdmittedDirtyRectanglesApplyInOrder() throws {
        let queue = DispatchQueue(label: "test.frames.ordered")
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        defer { gate.signal(); queue.sync {} }
        let (session, guest) = try connectedSession(queue: queue, bytes: 8, count: 2)
        defer { session.close(); guest.close() }
        let admitted = expectation(description: "both frames delivered")
        session.onWindowsChanged = { _ in admitted.fulfill() }
        let applied = expectation(description: "both frames applied")
        applied.expectedFulfillmentCount = 2
        session.onFrame = { _ in applied.fulfill() }
        guest.send(frame(7)); guest.send(frame(8))
        guest.send(.windowList(WindowList(windows: [])))
        wait(for: [admitted], timeout: 2)
        gate.signal()
        wait(for: [applied], timeout: 2)
        XCTAssertTrue(session.isReady)
        XCTAssertEqual(session.framebuffer.generation, 3) // one allocation and two writes
        XCTAssertEqual(session.framebuffer.surface?.baseAddress.load(as: UInt8.self), 8)
    }

    func testCompletedAndInvalidFramesReleaseBudget() throws {
        let queue = DispatchQueue(label: "test.frames.release")
        let (session, guest) = try connectedSession(queue: queue, bytes: 4, count: 1)
        defer { session.close(); guest.close(); queue.sync {} }
        let invalid = expectation(description: "invalid frame rejected")
        session.onLog = { if $0.contains("dropping frame") { invalid.fulfill() } }
        guest.send(frame(valid: false))
        wait(for: [invalid], timeout: 2)
        for value: UInt8 in [7, 8] {
            let applied = expectation(description: "frame \(value) applied")
            session.onFrame = { _ in applied.fulfill() }
            guest.send(frame(value))
            wait(for: [applied], timeout: 2)
            XCTAssertTrue(session.isReady)
            XCTAssertEqual(session.framebuffer.surface?.baseAddress.load(as: UInt8.self), value)
        }
    }
}
