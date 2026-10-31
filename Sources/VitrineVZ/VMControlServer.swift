import Foundation
import VitrineCore

/// Serves `VMControl` requests for one running VM on `<socketDirectory>/control.sock`. Each
/// connection carries one request line and gets one response line; requests are handled on the
/// main actor by `handler`.
final class VMControlServer: @unchecked Sendable {
    private let path: String
    private let fd: Int32
    private let handler: @MainActor (VMControl.Request) async -> VMControl.Response
    private let queue = DispatchQueue(label: "vitrine.control.accept")
    /// Blocking socket reads and writes happen here, never on Swift's cooperative thread pool (a few
    /// idle connections would otherwise stall every async task in the app).
    private let io = DispatchQueue(label: "vitrine.control.io", attributes: .concurrent)
    private var closed = false
    /// True while `acceptLoop` runs: it then closes the listening descriptor itself when it
    /// returns, so `stop` never closes a descriptor `accept` may still be about to use (its number
    /// could be reused by the next server's socket, which this loop would then answer for).
    private var accepting = false
    private let lock = NSLock()

    init(bundle: VMBundle, handler: @escaping @MainActor (VMControl.Request) async -> VMControl.Response) throws {
        let url = VMControl.socketURL(for: bundle)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        path = url.path
        self.handler = handler
        guard let listener = try? UnixSocket.listen(path: path, mode: 0o600) else {
            throw VitrineError.io("could not listen on \(path)")
        }
        fd = listener
        queue.async { [weak self] in self?.acceptLoop() }
    }

    deinit { stop() }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        shutdown(fd, SHUT_RDWR) // wakes a blocked accept, which then sees `closed`
        if !accepting { close(fd) } // the loop never started or has already returned
        unlink(path)
    }

    private func acceptLoop() {
        lock.lock()
        if closed { lock.unlock(); return } // stopped before the loop ran; `stop` closed the descriptor
        accepting = true
        lock.unlock()
        defer {
            lock.lock()
            accepting = false
            let stopped = closed
            lock.unlock()
            if stopped { close(fd) }
        }
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return // closed (or the listener broke: `stop` closes the descriptor then)
            }
            var tv = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let handler = self.handler
            io.async {
                func reply(_ response: VMControl.Response) {
                    defer { close(client) }
                    guard var data = try? JSONEncoder().encode(response) else { return }
                    data.append(0x0A)
                    UnixSocket.writeAll(client, data)
                }
                let request: VMControl.Request
                do {
                    guard let line = try VMControl.readLine(client) else { close(client); return }
                    request = try JSONDecoder().decode(VMControl.Request.self, from: line)
                } catch {
                    reply(.failure(error))
                    return
                }
                Task { @MainActor in
                    let response = await handler(request)
                    self.io.async { reply(response) }
                }
            }
        }
    }
}
