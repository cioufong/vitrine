import Foundation
import VitrineCore
import VitrineQEMU
import VitrineVZ
import VitrineAgentHost

/// `vitrinectl mcp`: a Model Context Protocol server on stdin/stdout (JSON-RPC 2.0, one message per
/// line) that lets an AI agent create (unattended installs), list, start and stop VMs, look at their
/// screens, type and click, run commands over SSH, copy files and take snapshots. There is
/// deliberately no tool that deletes a VM.
/// Everything runs as the current user with the same reach as `vitrinectl` itself.
enum MCPServer {
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let output = DispatchQueue(label: "vitrine.mcp.output")
    static let work = DispatchQueue(label: "vitrine.mcp.work", attributes: .concurrent)
    nonisolated(unsafe) static var protocolOut: FileHandle = .standardOutput
    /// Last screenshot scale per VM (display pixels per image pixel), so `click` takes coordinates
    /// in the image the agent was shown.
    nonisolated(unsafe) static var scales: [String: Double] = [:]
    static let scalesLock = NSLock()
    /// Serializes create_vm's "is the name free?" check with starting its process.
    static let createLock = NSLock()

    static func run() -> Never {
        // The protocol owns stdout: anything else printed (by a library, say) goes to stderr instead.
        // Close-on-exec: a VM runner started by start_vm must not hold the client's pipe open.
        let saved = fcntl(STDOUT_FILENO, F_DUPFD_CLOEXEC, 0)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        protocolOut = FileHandle(fileDescriptor: saved, closeOnDealloc: false)
        Thread.detachNewThread {
            while let line = readLine(strippingNewline: true) {
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                work.async { handle(line) }
            }
            // The client closed stdin: let in-flight replies drain, then exit.
            work.async(flags: .barrier) { output.async { exit(0) } }
        }
        RunLoop.main.run()
        exit(0)
    }

    // MARK: JSON-RPC

    static func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        output.async {
            protocolOut.write(data)
            protocolOut.write(Data([0x0A]))
        }
    }

    static func reply(_ id: Any, result: Any) { send(["jsonrpc": "2.0", "id": id, "result": result]) }
    static func replyError(_ id: Any, _ code: Int, _ message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    static func handle(_ line: String) {
        guard let msg = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            replyError(NSNull(), -32700, "parse error")
            return
        }
        guard let method = msg["method"] as? String else { return } // a response to us; we send no requests
        guard let id = msg["id"] else { return } // notifications (initialized, cancelled) need no answer
        let params = msg["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            reply(id, result: [
                "protocolVersion": supportedVersions.contains(asked) ? asked : supportedVersions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "vitrine", "title": "Vitrine", "version": "0.1.0"],
                "instructions": instructions,
            ])
        case "ping":
            reply(id, result: [String: Any]())
        case "tools/list":
            reply(id, result: ["tools": tools.map(\.json)])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard let tool = tools.first(where: { $0.name == name }) else {
                replyError(id, -32602, "unknown tool \(name)")
                return
            }
            do {
                reply(id, result: ["content": try tool.run(Arguments(values: arguments)), "isError": false])
            } catch {
                reply(id, result: ["content": [text(error.localizedDescription)], "isError": true])
            }
        default:
            replyError(id, -32601, "method not found: \(method)")
        }
    }

    static let instructions = """
    Vitrine runs macOS, Linux and Windows virtual machines on this Mac. Start with list_vms. \
    create_vm installs a new Debian 13, Windows 11 or macOS VM unattended (with a guest account \
    whose password Vitrine keeps) and boots it; follow it with create_status. \
    Look at a guest with screenshot, then click (coordinates are pixels of the last screenshot), \
    type_text and press_keys; these act as a USB keyboard and mouse, so they also work at login \
    screens and in installers. Text a US keyboard can't type (accents, CJK, emoji) goes through \
    the guest agent once a user is logged in. exec, push_file and pull_file need the guest's SSH account (set up by \
    Vitrine's unattended installs). A VM started with start_vm keeps running after this server exits.
    """

    // MARK: Tools

    struct Arguments {
        let values: [String: Any]
        func string(_ key: String) throws -> String {
            guard let s = values[key] as? String, !s.isEmpty else { throw VitrineError.invalidConfig("missing \(key)") }
            return s
        }
        func optionalString(_ key: String) -> String? { values[key] as? String }
        func int(_ key: String) throws -> Int {
            // Checked conversions: a huge or non-finite number is an error, not a trap.
            if let n = values[key] as? Int { return n }
            if let d = values[key] as? Double, d.isFinite, let n = Int(exactly: d) { return n }
            throw VitrineError.invalidConfig("missing, non-integer or out-of-range \(key)")
        }
        func number(_ key: String) -> Double? { (values[key] as? NSNumber)?.doubleValue }
        func bool(_ key: String) -> Bool { values[key] as? Bool ?? false }
        func vm() throws -> VMBundle { try VMLibrary.find(try string("name")) }
    }

    struct Tool {
        let name: String
        let title: String
        let description: String
        var properties: [String: [String: Any]] = [:]
        var required: [String] = []
        var readOnly = false
        var destructive = false
        let run: (Arguments) throws -> [[String: Any]]

        var json: [String: Any] {
            [
                "name": name, "title": title, "description": description,
                "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any],
                "annotations": ["title": title, "readOnlyHint": readOnly, "destructiveHint": destructive,
                                "idempotentHint": readOnly, "openWorldHint": false],
            ]
        }
    }

    static func text(_ s: String) -> [String: Any] { ["type": "text", "text": s] }
    static let vmName: [String: Any] = ["type": "string", "description": "VM name (from list_vms)"]

    static func json(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Runs async work (the SSH helpers) from a worker thread.
    static func blocking<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<T, Error>!
        Task.detached {
            do { result = .success(try await body()) } catch { result = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return try result.get()
    }

    static func summary(_ b: VMBundle) -> [String: Any] {
        var d: [String: Any] = ["name": b.name, "state": status(of: b)]
        if let c = try? b.loadConfig() {
            d["os"] = c.guestOS.rawValue
            d["backend"] = c.effectiveBackend.rawValue
            d["architecture"] = c.effectiveArchitecture.rawValue
            d["cpus"] = c.cpuCount
            d["memoryMiB"] = c.memoryMiB
        }
        return d
    }

    static let tools: [Tool] = [
        Tool(name: "create_vm", title: "Create VM",
             description: """
             Creates a VM and installs its OS unattended, in the background: Debian 13 (Xfce desktop, or headless with desktop=false; a few \
             minutes), Windows 11 (Arm64 by default, from a cached or given ISO; about 20 minutes, x64 emulated about 2 hours) or macOS \
             (the latest IPSW this Mac supports; needs a macOS 27 host). A guest account is created with a random password that Vitrine \
             keeps for exec, push_file and pull_file; it is never shown. With start=true (default) the VM boots as soon as it is created \
             and finishes setup by itself. Returns at once; poll create_status.
             """,
             properties: ["name": ["type": "string", "description": "New VM name (letters, digits, . - _)"],
                          "os": ["type": "string", "enum": VMCreationJob.Kind.allCases.map(\.rawValue)],
                          "desktop": ["type": "boolean", "description": "Debian: Xfce desktop (default true)"],
                          "arch": ["type": "string", "enum": ["arm64", "x64"], "description": "Windows: arm64 (default, fast) or x64 (emulated, slow)"],
                          "image": ["type": "string", "description": "Windows: installer ISO path (default: the newest cached one). macOS: IPSW path or latest"],
                          "username": ["type": "string", "description": "Guest account (default vitrine)"],
                          "cpus": ["type": "integer", "minimum": 1, "maximum": 64],
                          "memory": ["type": "string", "description": "e.g. 8G"],
                          "disk": ["type": "string", "description": "e.g. 80G"],
                          "start": ["type": "boolean", "description": "Boot the VM once it is created (default true)"]],
             required: ["name", "os"]) { a in
            [text(try createVM(a))]
        },
        Tool(name: "create_status", title: "Creation status",
             description: "Progress of a VM started with create_vm: creating, failed (with the error), created, or running (booted; setup continues inside the guest), with the last lines of its log.",
             properties: ["name": vmName], required: ["name"], readOnly: true) { a in
            [text(try creationStatus(try a.string("name")))]
        },
        Tool(name: "clone_vm", title: "Clone VM",
             description: "Makes an instant copy (APFS clone) of a shut-down VM with its own MAC address and identity; the guest account carries over.",
             properties: ["name": vmName, "new_name": ["type": "string"]], required: ["name", "new_name"]) { a in
            let b = try a.vm()
            let newName = try a.string("new_name")
            guard VMCreationJob.isValidVMName(newName) else { throw VitrineError.invalidConfig("bad new_name \(newName)") }
            guard b.runningPID() == nil else { throw VitrineError.invalidConfig("shut \(b.name) down first") }
            let dest = VMLibrary.bundleURL(named: newName)
            guard !FileManager.default.fileExists(atPath: dest.path) else { throw VitrineError.invalidConfig("a VM named \(newName) exists") }
            let out = try VMCloner.clone(b, to: dest, newName: newName)
            return [text("cloned \(b.name) to \(out.name)")]
        },
        Tool(name: "list_vms", title: "List VMs",
             description: "Lists the VMs in the Vitrine library with their state (running, suspended, stopped), OS and size.",
             readOnly: true) { _ in
            [text(json(VMLibrary.list().map(summary)))]
        },
        Tool(name: "vm_info", title: "VM details",
             description: "A VM's state, guest IP address (when it has a DHCP lease) and full configuration.",
             properties: ["name": vmName], required: ["name"], readOnly: true) { a in
            let b = try a.vm()
            let c = try b.loadConfig()
            var d = summary(b)
            d["ip"] = b.guestIPAddress(c) ?? NSNull()
            d["path"] = b.url.path
            d["config"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(c))) ?? [:]
            return [text(json(d))]
        },
        Tool(name: "start_vm", title: "Start VM",
             description: "Starts (or resumes) a VM in the background. With gui=true it opens a window on the Mac. The VM keeps running after this server exits; stop it with stop_vm.",
             properties: ["name": vmName, "gui": ["type": "boolean", "description": "Show the VM in a window (default false: headless)"]],
             required: ["name"]) { a in
            let b = try a.vm()
            if b.runningPID() != nil { return [text("\(b.name) is already running")] }
            try spawnRunner(b, gui: a.bool("gui"))
            let deadline = Date().addingTimeInterval(120)
            while b.runningPID() == nil, Date() < deadline { usleep(250_000) }
            guard b.runningPID() != nil else {
                throw VitrineError.backend("\(b.name) didn't start; see \(runnerLog(b).path)")
            }
            return [text("\(b.name) is starting. Use screenshot to watch it boot; exec works once the guest's SSH server is up.")]
        },
        Tool(name: "stop_vm", title: "Shut down VM",
             description: "Shuts a running VM down (an ACPI power button press; force=true pulls the plug, losing unsaved guest data).",
             properties: ["name": vmName, "force": ["type": "boolean", "description": "Power off immediately instead of asking the guest"]],
             required: ["name"], destructive: true) { a in
            [text(try stopVM(try a.vm(), suspend: false, force: a.bool("force")))]
        },
        Tool(name: "suspend_vm", title: "Suspend VM",
             description: "Saves a running VM's memory to disk and stops it; start_vm resumes it where it was.",
             properties: ["name": vmName], required: ["name"]) { a in
            [text(try stopVM(try a.vm(), suspend: true, force: false))]
        },
        Tool(name: "screenshot", title: "Screenshot",
             description: "Returns the VM's screen as a PNG image. click coordinates refer to this image's pixels.",
             properties: ["name": vmName,
                          "max_width": ["type": "integer", "description": "Scale down to at most this many pixels wide (default 1280)", "minimum": 64]],
             required: ["name"], readOnly: true) { a in
            let b = try a.vm()
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-mcp-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: file) }
            let full = try VMAutomation.screenshot(b, to: file)
            let (png, shown) = try VMAutomation.scaledPNG(file, maxWidth: max(64, (try? a.int("max_width")) ?? 1280))
            scalesLock.withLock { scales[b.url.path] = Double(full.width) / Double(max(1, shown.width)) }
            return [
                ["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"],
                text("\(b.name): display \(full.width)×\(full.height), image \(shown.width)×\(shown.height)"),
            ]
        },
        Tool(name: "click", title: "Click",
             description: "Moves the mouse to (x, y) in the last screenshot's pixels (origin top left) and clicks. button: left (default), right, or none to only move.",
             properties: ["name": vmName, "x": ["type": "integer"], "y": ["type": "integer"],
                          "button": ["type": "string", "enum": ["left", "right", "none"]],
                          "double": ["type": "boolean", "description": "Double-click"]],
             required: ["name", "x", "y"], destructive: true) { a in
            let b = try a.vm()
            let scale = scalesLock.withLock { scales[b.url.path] } ?? 1
            let (imageX, imageY) = (try a.int("x"), try a.int("y"))
            // Bounded before scaling, so the product always fits an Int (no display is this large).
            func displayPixel(_ v: Int) throws -> Int {
                guard (0...(1 << 20)).contains(v), let p = Int(exactly: (Double(v) * scale).rounded(.towardZero)) else {
                    throw VitrineError.invalidConfig("(\(imageX), \(imageY)) is outside the screenshot")
                }
                return p
            }
            let x = try displayPixel(imageX), y = try displayPixel(imageY)
            let button = a.optionalString("button") ?? "left"
            try VMAutomation.pointer(b, x: x, y: y, button: button == "none" ? nil : button, clicks: a.bool("double") ? 2 : 1)
            return [text(button == "none" ? "moved" : "clicked")]
        },
        Tool(name: "type_text", title: "Type text",
             description: "Types text into the focused place in the guest; a newline presses Return. method: keyboard = keys on the VM's US-layout keyboard (works at boot menus, installers and login screens; only characters a US keyboard has, and the guest should use a US layout); agent = the guest agent inserts the text (any characters, such as accents, CJK or emoji, whatever the guest's layout; needs the agent connected in a logged-in session); auto (default) = keyboard when every character is on it, agent otherwise. At most \(VMControl.maxKeyChords) characters per call; split longer text.",
             properties: ["name": vmName, "text": ["type": "string"],
                          "method": ["type": "string", "enum": ["auto", "keyboard", "agent"]]],
             required: ["name", "text"], destructive: true) { a in
            let b = try a.vm()
            let s = try a.string("text")
            let raw = a.optionalString("method") ?? "auto"
            guard let method = VMAutomation.TypingMethod(rawValue: raw) else {
                throw VitrineError.invalidConfig("method is auto, keyboard or agent, not \(raw)")
            }
            let used = try VMAutomation.type(b, s, method: method)
            return [text("typed \(s.count) characters \(used)")]
        },
        Tool(name: "press_keys", title: "Press keys",
             description: "Presses a key or combination, e.g. ret, esc, tab, f5, ctrl+c, ctrl+alt+delete, cmd+space, alt+tab, shift+tab, up. Separate several with spaces (at most \(VMControl.maxKeyChords) per call).",
             properties: ["name": vmName, "keys": ["type": "string"]], required: ["name", "keys"], destructive: true) { a in
            let b = try a.vm()
            let chords = try a.string("keys").split(separator: " ").map { try KeyNames.chord(named: String($0)) }
            try VMAutomation.keys(b, chords)
            return [text("pressed \(chords.map { $0.joined(separator: "+") }.joined(separator: " "))")]
        },
        Tool(name: "exec", title: "Run command",
             description: "Runs a shell command in the guest over SSH and returns its output (cmd.exe on Windows guests).",
             properties: ["name": vmName, "command": ["type": "string"]], required: ["name", "command"], destructive: true) { a in
            let b = try a.vm()
            let command = try a.string("command")
            let out = try blocking { try await AgentInstaller.run(in: b, command: command) }
            return [text(out.isEmpty ? "(no output)" : out)]
        },
        Tool(name: "push_file", title: "Copy into guest", description: "Copies a file or folder from the Mac into the guest (scp).",
             properties: ["name": vmName, "local_path": ["type": "string"], "guest_path": ["type": "string"]],
             required: ["name", "local_path", "guest_path"], destructive: true) { a in
            let b = try a.vm()
            let local = URL(fileURLWithPath: (try a.string("local_path") as NSString).expandingTildeInPath).standardizedFileURL
            let remote = try a.string("guest_path")
            guard FileManager.default.fileExists(atPath: local.path) else { throw VitrineError.invalidConfig("\(local.path) not found") }
            try blocking { try await AgentInstaller.push(in: b, local: local, remote: remote) }
            return [text("copied \(local.path) to \(b.name):\(remote)")]
        },
        Tool(name: "pull_file", title: "Copy from guest", description: "Copies a file or folder from the guest to the Mac (scp).",
             properties: ["name": vmName, "guest_path": ["type": "string"], "local_path": ["type": "string"]],
             required: ["name", "guest_path", "local_path"], destructive: true) { a in
            let b = try a.vm()
            let local = URL(fileURLWithPath: (try a.string("local_path") as NSString).expandingTildeInPath).standardizedFileURL
            let remote = try a.string("guest_path")
            try blocking { try await AgentInstaller.pull(in: b, remote: remote, local: local) }
            return [text("copied \(b.name):\(remote) to \(local.path)")]
        },
        Tool(name: "serial_console", title: "Serial console",
             description: "Sends text to the guest's serial console (a newline presses Return) and returns what it prints until the regular expression `expect` matches or `timeout` seconds pass. Useful for Linux guests without a network.",
             properties: ["name": vmName, "send": ["type": "string"], "expect": ["type": "string"],
                          "timeout": ["type": "number", "description": "Seconds (default 10, at most 120)"]],
             required: ["name"], destructive: true) { a in
            let b = try a.vm()
            var received = Data()
            let timeout = min(120, max(1, a.number("timeout") ?? 10))
            let status = try SerialConsole.exchange(b, send: a.optionalString("send"), expect: a.optionalString("expect"),
                                                    timeout: timeout) { received.append($0) }
            let out = String(decoding: received, as: UTF8.self)
            return [text((status == 0 ? "" : "(expect did not match within \(Int(timeout)) s)\n") + out)]
        },
        Tool(name: "list_snapshots", title: "List snapshots", description: "Lists a VM's snapshots.",
             properties: ["name": vmName], required: ["name"], readOnly: true) { a in
            let fmt = ISO8601DateFormatter()
            let snaps = SnapshotStore(bundle: try a.vm()).list().map {
                ["id": String($0.id.uuidString.prefix(8)), "name": $0.name, "created": fmt.string(from: $0.createdAt),
                 "includesMemory": $0.includesMemory] as [String: Any]
            }
            return [text(json(snaps))]
        },
        Tool(name: "create_snapshot", title: "Create snapshot",
             description: "Saves the VM's disks (and memory, when it is suspended) as a named snapshot.",
             properties: ["name": vmName, "snapshot": ["type": "string", "description": "Snapshot name"]],
             required: ["name", "snapshot"]) { a in
            let s = try SnapshotStore(bundle: try a.vm()).create(name: try a.string("snapshot"))
            return [text("created snapshot \(s.name) (\(s.id.uuidString.prefix(8)))\(s.includesMemory ? " with memory state" : "")")]
        },
        Tool(name: "restore_snapshot", title: "Restore snapshot",
             description: "Rolls the VM back to a snapshot (by name or id); everything changed since is lost. The VM must be shut down.",
             properties: ["name": vmName, "snapshot": ["type": "string"]], required: ["name", "snapshot"], destructive: true) { a in
            let store = SnapshotStore(bundle: try a.vm())
            let key = try a.string("snapshot")
            guard let s = store.find(key) ?? store.list().first(where: { $0.id.uuidString.lowercased().hasPrefix(key.lowercased()) }) else {
                throw VitrineError.invalidConfig("no snapshot \(key)")
            }
            try store.restore(s.id)
            return [text("restored \(s.name)")]
        },
        Tool(name: "delete_snapshot", title: "Delete snapshot",
             description: "Deletes one of a VM's snapshots (by name or id).",
             properties: ["name": vmName, "snapshot": ["type": "string"]], required: ["name", "snapshot"], destructive: true) { a in
            let store = SnapshotStore(bundle: try a.vm())
            let key = try a.string("snapshot")
            guard let s = store.find(key) ?? store.list().first(where: { $0.id.uuidString.lowercased().hasPrefix(key.lowercased()) }) else {
                throw VitrineError.invalidConfig("no snapshot \(key)")
            }
            try store.delete(s.id)
            return [text("deleted snapshot \(s.name)")]
        },
    ]

    // MARK: Creating VMs

    static func createVM(_ a: Arguments) throws -> String {
        let name = try a.string("name")
        guard let kind = VMCreationJob.Kind(rawValue: try a.string("os")) else {
            throw VitrineError.invalidConfig("os must be one of \(VMCreationJob.Kind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        var r = VMCreationJob.Request(name: name, kind: kind)
        if let u = a.optionalString("username"), !u.isEmpty { r.username = u }
        if a.values["desktop"] != nil { r.desktop = a.bool("desktop") }
        if a.values["start"] != nil { r.start = a.bool("start") }
        r.x64 = a.optionalString("arch") == "x64"
        r.image = a.optionalString("image").map { $0 == "latest" ? $0 : ($0 as NSString).expandingTildeInPath }
        if a.values["cpus"] != nil { r.cpus = try a.int("cpus") }
        r.memory = a.optionalString("memory")
        r.disk = a.optionalString("disk")

        var iso: URL?
        if kind == .windows {
            iso = r.image.map { URL(fileURLWithPath: $0) } ?? VMCreationJob.cachedWindowsISO(x64: r.x64)
            guard let found = iso, FileManager.default.fileExists(atPath: found.path) else {
                let page = r.x64 ? WindowsCreator.downloadPageX64 : WindowsCreator.downloadPageArm
                throw VitrineError.invalidConfig("no Windows 11 \(r.x64 ? "x64" : "Arm64") ISO: download one from \(page.absoluteString) and pass its path as image")
            }
        }
        if kind == .macOS {
            guard #available(macOS 27, *) else { throw VitrineError.invalidConfig("unattended macOS guests need a macOS 27 host") }
            if let path = r.image, path != "latest", !FileManager.default.fileExists(atPath: path) {
                throw VitrineError.invalidConfig("\(path) not found")
            }
        }
        let args = try VMCreationJob.arguments(for: r, windowsISO: iso)
        let job = VMCreationJob(name: name)

        try createLock.withLock {
            guard !FileManager.default.fileExists(atPath: VMLibrary.bundleURL(named: name).path) else {
                throw VitrineError.invalidConfig("a VM named \(name) exists (delete it with vitrinectl delete \(name) to start over)")
            }
            guard !job.isActive else { throw VitrineError.invalidConfig("\(name) is already being created; see create_status") }
            try job.reset()
            guard let exe = Bundle.main.executablePath else { throw VitrineError.io("can't find vitrinectl's own path") }
            let pid = try spawnDetached(["/bin/sh", "-c", VMCreationJob.shellScript, exe, r.start ? name : ""] + args,
                                        log: job.logURL, stdin: Data((VMCreationJob.generatePassword() + "\n").utf8))
            try job.begin(pid: pid)
        }

        // Option mistakes make the CLI exit at once: report them here rather than on the next call.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, job.isActive { usleep(200_000) }
        let status = job.status(bundle: nil)
        if status.state == .failed {
            throw VitrineError.backend("creating \(name) failed:\n" + status.log.joined(separator: "\n"))
        }
        let how: String
        switch kind {
        case .debian: how = "Debian's cloud image downloads (cached after the first time)\(r.desktop ? " and Xfce installs on first boot" : ""): a few minutes"
        case .windows: how = r.x64 ? "Windows 11 x64 setup is emulated and takes about two hours" : "Windows 11 setup takes about 20 minutes and restarts by itself"
        case .macOS: how = "macOS downloads its restore image if needed and installs in about 10 minutes"
        }
        return "creating \(name) (\(kind.rawValue), account \(r.username)). \(how). Poll create_status; " +
            (r.start ? "the VM boots by itself once it is created." : "then start it with start_vm.")
    }

    static func creationStatus(_ name: String) throws -> String {
        guard VMCreationJob.isValidVMName(name) else { throw VitrineError.invalidConfig("bad name \(name)") }
        let job = VMCreationJob(name: name)
        let url = VMLibrary.bundleURL(named: name)
        let bundle = FileManager.default.fileExists(atPath: url.path) ? VMBundle(url: url) : nil
        let st = job.status(bundle: bundle)
        var d: [String: Any] = ["name": name, "state": st.state.rawValue, "log": st.log]
        if let code = st.exitCode { d["exitCode"] = code }
        if let b = bundle, let c = try? b.loadConfig() {
            d["os"] = c.guestOS.rawValue
            d["ip"] = b.guestIPAddress(c) ?? NSNull()
            d["agentInstalled"] = c.account?.agentInstalled ?? false
        }
        switch st.state {
        case .running where d["agentInstalled"] as? Bool == true:
            d["next"] = "Set up, with Vitrine's agent installed. Once it has booted, exec, screenshot, click and type_text work; type_text sends non-US characters through the agent (in macOS guests once it is allowed Accessibility)."
        case .running:
            d["next"] = "The guest is booting and finishing setup; screenshot shows how far. exec works once its SSH server is up (agentInstalled turns true when Vitrine's agent is in)."
        case .created:
            d["next"] = "Created. start_vm boots it; setup finishes inside the guest."
        case .failed:
            d["next"] = "See log. A partly created VM may remain; delete it with vitrinectl delete \(name) before trying again."
        case .unknown:
            d["next"] = "No create_vm job for \(name)."
        case .creating:
            break
        }
        return json(d)
    }

    // MARK: Starting VMs

    static func runnerLog(_ b: VMBundle) -> URL { b.url.appendingPathComponent("vitrinectl-run.log") }

    /// Starts `vitrinectl run` in its own session, detached from this server's stdio, so the VM
    /// outlives the MCP client.
    static func spawnRunner(_ b: VMBundle, gui: Bool) throws {
        guard let exe = Bundle.main.executablePath else { throw VitrineError.io("can't find vitrinectl's own path") }
        _ = try spawnDetached([exe, "run", b.url.path] + (gui ? ["--gui"] : []), log: runnerLog(b))
    }

    /// Starts a process in its own session with stdout and stderr appended to `log`, and stdin from
    /// /dev/null or from a pipe that receives `stdin` and is then closed.
    static func spawnDetached(_ args: [String], log: URL, stdin: Data? = nil) throws -> pid_t {
        var pipeFDs: [Int32] = [-1, -1]
        if stdin != nil {
            guard pipe(&pipeFDs) == 0 else { throw VitrineError.io("pipe failed (\(String(cString: strerror(errno))))") }
        }
        defer { if pipeFDs[0] >= 0 { close(pipeFDs[0]) } }
        var attr = posix_spawnattr_t(bitPattern: 0)
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Inherit only the descriptors set up below, not sockets or pipes other tool calls hold open.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions = posix_spawn_file_actions_t(bitPattern: 0)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if stdin != nil {
            posix_spawn_file_actions_adddup2(&actions, pipeFDs[0], STDIN_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, log.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, args[0], &actions, &attr, &cargs, environ)
        guard rc == 0 else {
            if pipeFDs[1] >= 0 { close(pipeFDs[1]) }
            throw VitrineError.io("couldn't start \(args[0]) (\(String(cString: strerror(rc))))")
        }
        if let data = stdin {
            // A password line is far below the pipe buffer, so this write never blocks.
            data.withUnsafeBytes { _ = write(pipeFDs[1], $0.baseAddress, $0.count) }
            close(pipeFDs[1])
        }
        // The runner is still our child: reap it when its VM stops, or it lingers as a zombie.
        let child = pid
        Thread.detachNewThread {
            while waitpid(child, nil, 0) < 0, errno == EINTR {}
        }
        return pid
    }
}
