import Foundation
import ImageIO
import UniformTypeIdentifiers
import VitrineCore
import VitrineQEMU

/// Screenshots, typing and clicks for any running VM, as `vitrinectl screenshot|keys|click` and the
/// MCP server need them. QEMU guests are driven over the tools QMP socket (works whichever process
/// owns the VM); Virtualization.framework guests through their owner's control socket.
enum VMAutomation {
    struct Size { var width: Int; var height: Int }

    /// Connects to a QEMU guest's tools QMP socket and runs `body` with it while holding the VM's
    /// input lock; nil when the VM isn't a QEMU guest. QEMU serves that socket to one client at a
    /// time, and a key or click sequence must not interleave with another caller's (parallel MCP
    /// tool calls, other vitrinectl processes). Owners of Virtualization.framework VMs serialize
    /// their input themselves.
    static func withQMP<T>(_ b: VMBundle, _ body: (QMPClient) throws -> T) throws -> T? {
        let socket = QEMUSockets(directory: b.socketDirectory).qmpTools.path
        guard isQEMU(b) else { return nil }
        return try withInputLock(b) { try body(try QMPClient(socketPath: socket, timeout: 5)) }
    }

    static func isQEMU(_ b: VMBundle) -> Bool {
        FileManager.default.fileExists(atPath: QEMUSockets(directory: b.socketDirectory).qmpTools.path)
    }

    /// Holds the VM's input lock (see `withQMP`) while `body` runs.
    static func withInputLock<T>(_ b: VMBundle, _ body: () throws -> T) throws -> T {
        let lock = b.socketDirectory.appendingPathComponent("input.lock").path
        let fd = open(lock, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw VitrineError.io("can't open \(lock): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw VitrineError.io("can't lock \(lock): \(String(cString: strerror(errno)))") }
        }
        return try body()
    }

    static func requireRunning(_ b: VMBundle) throws {
        guard b.runningPID() != nil else { throw VitrineError.invalidConfig("\(b.name) is not running") }
    }

    static func control(_ b: VMBundle, _ r: VMControl.Request) throws -> VMControl.Response {
        let resp = try VMControl.send(r, to: b, timeout: VMControl.automationTimeout)
        guard resp.ok else { throw VitrineError.backend(resp.error ?? "the VM's owner refused") }
        return resp
    }

    /// Saves the guest display as a full-resolution PNG.
    @discardableResult
    static func screenshot(_ b: VMBundle, to url: URL) throws -> Size {
        try requireRunning(b)
        if let size = try withQMP(b, { q -> Size in
            _ = try q.execute("screendump", arguments: ["filename": url.path, "format": "png"])
            guard let size = pngSize(url) else { throw VitrineError.backend("QEMU wrote no screenshot") }
            return size
        }) {
            return size
        }
        let r = try control(b, .init(op: .screenshot, paths: [url.path]))
        return Size(width: r.width ?? 0, height: r.height ?? 0)
    }

    /// Presses each chord (QEMU key names, see `KeyNames`) together and releases it.
    static func keys(_ b: VMBundle, _ chords: [[String]]) throws {
        guard chords.count <= VMControl.maxKeyChords else {
            throw VitrineError.invalidConfig("\(chords.count) keys are more than \(VMControl.maxKeyChords) at once; send them in parts")
        }
        try requireRunning(b)
        if try withQMP(b, { try QEMUKeyboard.send(chords, over: $0) }) == nil {
            _ = try control(b, .init(op: .keys, chords: chords))
        }
    }

    enum TypingMethod: String { case auto, keyboard, agent }

    /// Types `text` and says how ("on the keyboard", …): `keyboard` presses keys on the VM's
    /// US-layout keyboard (works before the guest is up, but only for characters a US keyboard
    /// has), `agent` has the guest agent insert the text (any character, any layout, logged-in
    /// session only; an agent that may not inject input has it pasted), `auto` uses the keyboard
    /// when it can type everything and the agent otherwise.
    @discardableResult
    static func type(_ b: VMBundle, _ text: String, method: TypingMethod = .auto) throws -> String {
        var chords: [[String]]?, notOnKeyboard: Error?
        if method != .agent {
            do { chords = try QEMUKeyboard.chords(for: text) } catch where method == .auto { notOnKeyboard = error }
        }
        if let chords {
            try keys(b, chords)
            return "on the keyboard"
        }
        guard text.count <= VMControl.maxKeyChords else {
            throw VitrineError.invalidConfig("\(text.count) characters are more than \(VMControl.maxKeyChords) at once; send them in parts")
        }
        try requireRunning(b)
        let request = VMControl.Request(op: .text, text: text)
        let response: VMControl.Response
        do {
            response = try isQEMU(b) ? withInputLock(b) { try control(b, request) } : control(b, request)
        } catch {
            guard let notOnKeyboard else { throw error }
            throw VitrineError.unsupported("\(reason(notOnKeyboard)); nor can the guest agent: \(reason(error))")
        }
        return response.via == "paste" ? "by pasting through the guest clipboard" : "through the guest agent"
    }

    /// An error's message without the category prefixes `VitrineError` adds (also the owner's,
    /// which arrives inside `.backend`), for joining two reasons into one sentence.
    private static func reason(_ error: Error) -> String {
        var m = error.localizedDescription
        for prefix in ["Virtual machine error: ", "Unsupported: "] where m.hasPrefix(prefix) {
            m.removeFirst(prefix.count)
        }
        return m
    }

    /// Moves the pointer to guest pixel (x, y), origin top left, and clicks `button` `clicks` times
    /// (no button: only moves).
    static func pointer(_ b: VMBundle, x: Int, y: Int, button: String?, clicks: Int) throws {
        try requireRunning(b)
        if let button, !["left", "right"].contains(button) { throw VitrineError.invalidConfig("button must be left or right") }
        if try withQMP(b, { try qemuPointer($0, x: x, y: y, button: button, clicks: clicks) }) == nil {
            _ = try control(b, .init(op: .pointer, x: x, y: y, button: button, clicks: clicks))
        }
    }

    private static func qemuPointer(_ q: QMPClient, x: Int, y: Int, button: String?, clicks: Int) throws {
        // QEMU's USB tablet takes absolute positions 0…32767 across the display, so its size is needed.
        let probe = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-size-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: probe) }
        _ = try q.execute("screendump", arguments: ["filename": probe.path, "format": "png"])
        guard let size = pngSize(probe), size.width > 0, size.height > 0 else { throw VitrineError.backend("couldn't read the display size") }
        guard x >= 0, y >= 0, x < size.width, y < size.height else {
            throw VitrineError.invalidConfig("(\(x), \(y)) is outside the \(size.width)×\(size.height) display")
        }
        func abs(_ v: Int, _ extent: Int) -> Int { min(32767, Int((Double(v) + 0.5) * 32768 / Double(extent))) }
        _ = try q.execute("input-send-event", arguments: ["events": [
            ["type": "abs", "data": ["axis": "x", "value": abs(x, size.width)]],
            ["type": "abs", "data": ["axis": "y", "value": abs(y, size.height)]],
        ]])
        guard let button else { return }
        usleep(50_000)
        for _ in 0..<max(1, min(clicks, 3)) {
            _ = try q.execute("input-send-event", arguments: ["events": [["type": "btn", "data": ["down": true, "button": button]]]])
            usleep(30_000)
            _ = try q.execute("input-send-event", arguments: ["events": [["type": "btn", "data": ["down": false, "button": button]]]])
            usleep(60_000)
        }
    }

    static func pngSize(_ url: URL) -> Size? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return Size(width: w, height: h)
    }

    /// PNG bytes of `url` scaled down to at most `maxWidth` pixels wide, and the size they have.
    static func scaledPNG(_ url: URL, maxWidth: Int) throws -> (Data, Size) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw VitrineError.io("unreadable screenshot") }
        guard image.width > maxWidth else {
            return (try Data(contentsOf: url), Size(width: image.width, height: image.height))
        }
        let w = maxWidth, h = max(1, Int((Double(image.height) * Double(maxWidth) / Double(image.width)).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw VitrineError.io("couldn't scale the screenshot")
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { throw VitrineError.io("couldn't scale the screenshot") }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            throw VitrineError.io("couldn't encode the screenshot")
        }
        CGImageDestinationAddImage(dest, scaled, nil)
        guard CGImageDestinationFinalize(dest) else { throw VitrineError.io("couldn't encode the screenshot") }
        return (out as Data, Size(width: w, height: h))
    }
}
