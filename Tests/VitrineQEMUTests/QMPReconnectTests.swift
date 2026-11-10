import XCTest
import Darwin
@testable import VitrineQEMU
import VitrineCore

/// One slow reply (a QEMU main loop busy for longer than the command timeout) must not leave QMP
/// unusable for the rest of the run. The socket is server=on,wait=off, so the client reconnects
/// before its next command; the timed-out command is never sent again, and the stale reply on the
/// old connection is never taken for the next command's.
final class QMPReconnectTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        signal(SIGPIPE, SIG_IGN)
    }

    func testReconnectsAfterATimedOutCommand() throws {
        let path = NSTemporaryDirectory() + "qmp-\(UUID().uuidString.prefix(8)).sock"
        let listener = try UnixSocket.listen(path: path)
        defer { Darwin.close(listener); unlink(path) }

        let log = CommandLog()
        let server = Thread {
            // Session 1: answers the handshake, then sits on "stop" past the client's timeout and
            // answers it late.
            guard let a = FakeQMP.accept(listener), FakeQMP.handshake(a, log: log, session: 1) else { return }
            if let cmd = FakeQMP.command(a) { log.add(1, cmd) }
            Thread.sleep(forTimeInterval: 1.5)
            _ = UnixSocket.writeAll(a, Data(#"{"return": {"stale": true}}"#.utf8 + [0x0A]))
            // Session 2: a normal QEMU.
            guard let b = FakeQMP.accept(listener) else { Darwin.close(a); return }
            if FakeQMP.handshake(b, log: log, session: 2) {
                while let cmd = FakeQMP.command(b) {
                    log.add(2, cmd)
                    let reply: String
                    switch cmd {
                    case "query-status": reply = #"{"return": {"status": "paused", "running": false}}"#
                    case "query-name": reply = #"{"return": {"name": "fresh"}}"#
                    default: reply = #"{"return": {}}"#
                    }
                    _ = UnixSocket.writeAll(b, Data(#"{"timestamp": {}, "event": "RESUME"}"#.utf8 + [0x0A]))
                    _ = UnixSocket.writeAll(b, Data(reply.utf8 + [0x0A]))
                }
            }
            Darwin.close(a); Darwin.close(b)
        }
        server.start()

        let client = try QMPClient(socketPath: path, timeout: 3, commandTimeout: 1)
        let reconnected = Box<String?>()
        let seenAtReconnect = Box<[String]>()
        client.onReconnect = { status in
            reconnected.set(status)
            seenAtReconnect.set(log.commands(2))
        }

        XCTAssertThrowsError(try client.execute("stop")) { error in
            XCTAssertTrue(error.localizedDescription.contains("timed out"), "\(error)")
        }
        Thread.sleep(forTimeInterval: 1.0) // the stale reply lands on the old connection
        let result = try client.execute("query-name") as? [String: Any]
        XCTAssertEqual(result?["name"] as? String, "fresh", "answered by the new connection, not the stale reply")
        XCTAssertEqual(try client.status(), "paused")

        XCTAssertEqual(log.commands(1), ["qmp_capabilities", "stop"])
        XCTAssertEqual(log.commands(2), ["qmp_capabilities", "query-status", "query-name", "query-status"],
                       "reconnect reads the state once and never re-sends the timed-out command")
        XCTAssertEqual(reconnected.value, .some("paused"), "owner learns the state found after reconnecting")
        XCTAssertEqual(seenAtReconnect.value, ["qmp_capabilities", "query-status"],
                       "owner hears before the next command runs, so the state isn't already outdated")
    }

    /// If the new connection's own status query times out, its reply stream is out of step too:
    /// it must not be used, and the next command reconnects again.
    func testAReconnectThatTimesOutStaysBroken() throws {
        let path = NSTemporaryDirectory() + "qmp-\(UUID().uuidString.prefix(8)).sock"
        let listener = try UnixSocket.listen(path: path)
        defer { Darwin.close(listener); unlink(path) }
        let log = CommandLog()
        let server = Thread {
            // 1: stalls "stop". 2: stalls the reconnect's query-status, then answers it late.
            // 3: a normal QEMU.
            guard let a = FakeQMP.accept(listener), FakeQMP.handshake(a, log: log, session: 1) else { return }
            if let cmd = FakeQMP.command(a) { log.add(1, cmd) }
            guard let b = FakeQMP.accept(listener) else { Darwin.close(a); return }
            if FakeQMP.handshake(b, log: log, session: 2), let cmd = FakeQMP.command(b) {
                log.add(2, cmd)
                Thread.sleep(forTimeInterval: 1.5)
                _ = UnixSocket.writeAll(b, Data(#"{"return": {"status": "stale"}}"#.utf8 + [0x0A]))
            }
            guard let c = FakeQMP.accept(listener) else { Darwin.close(a); Darwin.close(b); return }
            if FakeQMP.handshake(c, log: log, session: 3) {
                while let cmd = FakeQMP.command(c) {
                    log.add(3, cmd)
                    let reply = cmd == "query-status" ? #"{"return": {"status": "running"}}"# : #"{"return": {"name": "fresh"}}"#
                    _ = UnixSocket.writeAll(c, Data(reply.utf8 + [0x0A]))
                }
            }
            Darwin.close(a); Darwin.close(b); Darwin.close(c)
        }
        server.start()

        let client = try QMPClient(socketPath: path, timeout: 3, commandTimeout: 1)
        let statuses = Box<[String?]>()
        client.onReconnect = { statuses.set((statuses.value ?? []) + [$0]) }
        XCTAssertThrowsError(try client.execute("stop"))
        XCTAssertThrowsError(try client.execute("query-name"), "reconnect's status query timed out")
        Thread.sleep(forTimeInterval: 1.0)
        let result = try client.execute("query-name") as? [String: Any]
        XCTAssertEqual(result?["name"] as? String, "fresh")
        XCTAssertEqual(log.commands(2), ["qmp_capabilities", "query-status"], "nothing sent on the out-of-step connection")
        XCTAssertEqual(log.commands(3), ["qmp_capabilities", "query-status", "query-name"])
        XCTAssertEqual(statuses.value ?? [], ["running"])
    }

    /// When QEMU is gone the next command fails promptly instead of waiting out a long timeout.
    func testFailsFastWhenTheServerIsGone() throws {
        let path = NSTemporaryDirectory() + "qmp-\(UUID().uuidString.prefix(8)).sock"
        let listener = try UnixSocket.listen(path: path)
        let server = Thread {
            guard let a = FakeQMP.accept(listener), FakeQMP.handshake(a, log: CommandLog(), session: 1) else { return }
            _ = FakeQMP.command(a)
            Darwin.close(a) // QEMU exits mid-command
        }
        server.start()
        let client = try QMPClient(socketPath: path, timeout: 3, commandTimeout: 5)
        XCTAssertThrowsError(try client.execute("quit"))
        Darwin.close(listener); unlink(path)
        let started = Date()
        XCTAssertThrowsError(try client.execute("query-status"))
        XCTAssertThrowsError(try client.execute("query-status"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }
}

private enum FakeQMP {
    static func accept(_ listener: Int32) -> Int32? {
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(listener, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    static func handshake(_ fd: Int32, log: CommandLog, session: Int) -> Bool {
        guard UnixSocket.writeAll(fd, Data(#"{"QMP": {"version": {}, "capabilities": []}}"#.utf8 + [0x0A])),
              let cmd = command(fd) else { return false }
        log.add(session, cmd)
        return UnixSocket.writeAll(fd, Data(#"{"return": {}}"#.utf8 + [0x0A]))
    }

    /// The "execute" name of the next command, nil once the client hung up.
    static func command(_ fd: Int32) -> String? {
        guard let line = try? UnixSocket.readLine(fd, limit: 1 << 16),
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        return obj["execute"] as? String
    }
}

private final class CommandLog: @unchecked Sendable {
    private let lock = NSLock()
    private var bySession: [Int: [String]] = [:]
    func add(_ session: Int, _ cmd: String) { lock.lock(); bySession[session, default: []].append(cmd); lock.unlock() }
    func commands(_ session: Int) -> [String] { lock.lock(); defer { lock.unlock() }; return bySession[session] ?? [] }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    func set(_ v: T) { lock.lock(); stored = v; lock.unlock() }
    var value: T? { lock.lock(); defer { lock.unlock() }; return stored }
}
