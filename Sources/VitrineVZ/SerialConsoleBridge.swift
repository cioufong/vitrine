import Foundation
import VitrineCore

/// Connects a Virtualization.framework serial port to `console.log` and a Unix socket
/// (`<socket dir>/serial.sock`), so `vitrinectl console` can type into the guest's console.
/// One client at a time; a new connection replaces the old one. The log keeps everything the
/// guest wrote, whether or not anyone was connected.
public final class SerialConsoleBridge: @unchecked Sendable {
    nonisolated(unsafe) private static var active: [String: SerialConsoleBridge] = [:]
    private static let registry = NSLock()

    /// What the guest reads (we write) and what the guest writes (we read).
    let toGuest = Pipe()
    let fromGuest = Pipe()
    private let log: FileHandle
    private let socketPath: String
    private let listener: Int32
    private let queue = DispatchQueue(label: "vitrine.serial-console")
    private var listenerSource: DispatchSourceRead?
    private var outputSource: DispatchSourceRead?
    private var inputSource: DispatchSourceWrite?
    private var pendingInput = Data()
    private var inputActive = false
    private var clientPaused = false
    private var clientSource: DispatchSourceRead?
    private var client: Int32 = -1
    private var closed = false

    /// Starts a bridge for `bundle`, replacing one left from an earlier run.
    static func start(bundle: VMBundle) throws -> SerialConsoleBridge {
        stop(bundle: bundle)
        let bridge = try SerialConsoleBridge(bundle: bundle)
        registry.lock(); active[bundle.url.path] = bridge; registry.unlock()
        return bridge
    }

    /// Stops the bridge of `bundle` (VM stopped).
    public static func stop(bundle: VMBundle) {
        registry.lock(); let b = active.removeValue(forKey: bundle.url.path); registry.unlock()
        b?.close()
    }

    private init(bundle: VMBundle) throws {
        if !FileManager.default.fileExists(atPath: bundle.consoleLogURL.path) {
            FileManager.default.createFile(atPath: bundle.consoleLogURL.path, contents: nil)
        }
        log = try FileHandle(forWritingTo: bundle.consoleLogURL)
        log.seekToEndOfFile()
        try FileManager.default.createDirectory(at: bundle.socketDirectory, withIntermediateDirectories: true)
        socketPath = bundle.socketDirectory.appendingPathComponent("serial.sock").path
        listener = try UnixSocket.listen(path: socketPath, mode: 0o600, backlog: 4)
        for fd in [listener, fromGuest.fileHandleForReading.fileDescriptor, toGuest.fileHandleForWriting.fileDescriptor] {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }

        let acceptSource = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        acceptSource.setEventHandler { [weak self] in self?.acceptClient() }
        let fd = listener
        acceptSource.setCancelHandler { Darwin.close(fd) }
        listenerSource = acceptSource

        let output = DispatchSource.makeReadSource(fileDescriptor: fromGuest.fileHandleForReading.fileDescriptor, queue: queue)
        output.setEventHandler { [weak self] in self?.readGuest() }
        let reader = fromGuest.fileHandleForReading
        output.setCancelHandler { try? reader.close() }
        outputSource = output

        let writer = toGuest.fileHandleForWriting
        let input = DispatchSource.makeWriteSource(fileDescriptor: writer.fileDescriptor, queue: queue)
        input.setEventHandler { [weak self] in self?.writeInput() }
        input.setCancelHandler { try? writer.close() }
        inputSource = input // resumed only while input is waiting for pipe space
        acceptSource.resume()
        output.resume()
    }

    private func acceptClient() {
        guard !closed else { return }
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        closeClient()
        client = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readClient(fd) }
        source.setCancelHandler { Darwin.close(fd) }
        clientSource = source
        source.resume()
    }

    private func readGuest() {
        guard !closed else { return }
        var buf = [UInt8](repeating: 0, count: 64 << 10)
        let n = read(fromGuest.fileHandleForReading.fileDescriptor, &buf, buf.count)
        guard n > 0 else {
            if n == 0 { outputSource?.cancel(); outputSource = nil }
            return
        }
        let data = Data(buf[0..<n])
        log.write(data)
        // A slow console must not stall the guest. Drop anything its socket cannot accept.
        if client >= 0 {
            let written = data.withUnsafeBytes { Darwin.write(client, $0.baseAddress!, $0.count) }
            if written < 0 && errno != EAGAIN && errno != EINTR { closeClient() }
        }
    }

    private func readClient(_ fd: Int32) {
        guard !closed, client == fd, pendingInput.isEmpty else { return }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        if n > 0 {
            pendingInput = Data(buf[0..<n])
            writeInput()
        } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
            closeClient()
        }
    }

    private func writeInput() {
        guard !closed, !pendingInput.isEmpty else { return }
        let n = pendingInput.withUnsafeBytes {
            Darwin.write(toGuest.fileHandleForWriting.fileDescriptor, $0.baseAddress!, $0.count)
        }
        if n > 0 {
            pendingInput.removeFirst(n)
        } else if n < 0 && errno != EAGAIN && errno != EINTR {
            closeClient()
            return
        }
        // Keep at most one read's input; let the socket backpressure the client while paused.
        if pendingInput.isEmpty {
            if inputActive { inputSource?.suspend(); inputActive = false }
            if clientPaused { clientSource?.resume(); clientPaused = false }
        } else {
            if !clientPaused { clientSource?.suspend(); clientPaused = true }
            if !inputActive { inputSource?.resume(); inputActive = true }
        }
    }

    private func closeClient() {
        pendingInput.removeAll()
        if inputActive { inputSource?.suspend(); inputActive = false }
        if clientPaused { clientSource?.resume(); clientPaused = false }
        client = -1
        clientSource?.setEventHandler {}
        clientSource?.cancel()
        clientSource = nil
    }

    private func close() {
        queue.sync {
            guard !closed else { return }
            closed = true
            closeClient()
            listenerSource?.cancel(); listenerSource = nil
            outputSource?.cancel(); outputSource = nil
            if !inputActive { inputSource?.resume() }
            inputSource?.cancel(); inputSource = nil
            unlink(socketPath)
            try? toGuest.fileHandleForReading.close()
            try? fromGuest.fileHandleForWriting.close()
            try? log.close()
        }
    }
}
