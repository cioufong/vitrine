import Foundation
import VitrineCore

/// `vitrinectl console`: the guest's serial console over `<socket dir>/serial.sock`.
enum SerialConsole {
    static func socketPath(_ bundle: VMBundle) -> String {
        bundle.socketDirectory.appendingPathComponent("serial.sock").path
    }

    static func connect(_ bundle: VMBundle) throws -> Int32 {
        let path = socketPath(bundle)
        guard FileManager.default.fileExists(atPath: path) else {
            throw VitrineError.unsupported("\(bundle.name) has no serial console right now (is it running?)")
        }
        return try UnixSocket.connect(path: path)
    }

    /// Interactive: the terminal is wired straight to the console until Ctrl-] is pressed.
    static func attach(_ bundle: VMBundle) throws -> Never {
        let fd = try connect(bundle)
        FileHandle.standardError.write(Data("Connected to \(bundle.name)'s serial console. Press Ctrl-] to detach.\r\n".utf8))
        var saved = termios()
        let isTTY = isatty(STDIN_FILENO) == 1
        if isTTY {
            tcgetattr(STDIN_FILENO, &saved)
            var raw = saved
            cfmakeraw(&raw)
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        }
        func restoreAndExit(_ code: Int32) -> Never {
            if isTTY { tcsetattr(STDIN_FILENO, TCSANOW, &saved) }
            FileHandle.standardError.write(Data("\r\nDetached.\n".utf8))
            exit(code)
        }
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { restoreAndExit(0) }
                _ = buf.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, n) }
            }
        }
        var buf = [UInt8](repeating: 0, count: 1024)
        while true {
            let n = read(STDIN_FILENO, &buf, buf.count)
            if n <= 0 { restoreAndExit(0) }
            if let i = buf[0..<n].firstIndex(of: 0x1D) { // Ctrl-]
                if i > 0 { UnixSocket.writeAll(fd, Data(buf[0..<i])) }
                restoreAndExit(0)
            }
            UnixSocket.writeAll(fd, Data(buf[0..<n]))
        }
    }

    /// Scripted: sends `text` (with \n escapes), then prints what the console says until `expect`
    /// (a regular expression) matches or `timeout` seconds pass. Exit status 1 when it never matched.
    static func exchange(_ bundle: VMBundle, send text: String?, expect: String?, timeout: Double,
                         output: (Data) -> Void = { FileHandle.standardOutput.write($0) }) throws -> Int32 {
        let fd = try connect(bundle)
        defer { close(fd) }
        let regex = try expect.map { try NSRegularExpression(pattern: $0) }
        if let text {
            let unescaped = text.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\r", with: "\r")
                .replacingOccurrences(of: "\\t", with: "\t")
            UnixSocket.writeAll(fd, Data(unescaped.utf8))
        }
        var received = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let left = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            guard poll(&p, 1, min(left, 200)) >= 0 else { break }
            if p.revents & Int16(POLLIN) != 0 {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                received.append(contentsOf: buf[0..<n])
                output(Data(buf[0..<n]))
                let s = String(decoding: received, as: UTF8.self)
                if let regex, regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil { return 0 }
            }
        }
        return regex == nil ? 0 : 1
    }
}
