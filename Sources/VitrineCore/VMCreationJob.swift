import Foundation

/// A VM being created in the background by a detached `vitrinectl create…` process (the MCP
/// server's create_vm). Its output and process id live in the library's `.creating` folder, so
/// create_status can report progress after the server that started it has exited.
public struct VMCreationJob: Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case debian = "debian-13", windows = "windows-11", macOS = "macos"
    }

    public struct Request: Sendable {
        public var name: String
        public var kind: Kind
        public var username = "vitrine"
        /// Debian: install the Xfce desktop (default) or stay headless.
        public var desktop = true
        /// Windows: x64 (emulated) instead of Arm64.
        public var x64 = false
        /// Windows: installer ISO. macOS: "latest" or a path to an IPSW.
        public var image: String?
        public var cpus: Int?
        public var memory: String?
        public var disk: String?
        /// Boot the new VM right after creating it, so Debian's and Windows' unattended setup and
        /// macOS's account creation finish without another call.
        public var start = true

        public init(name: String, kind: Kind) { self.name = name; self.kind = kind }
    }

    public enum State: String, Sendable {
        case creating, failed, created, running, unknown
    }

    public struct Status: Sendable {
        public var state: State
        public var exitCode: Int32?
        public var log: [String]
    }

    public let name: String
    public init(name: String) { self.name = name }

    public static var directory: URL { VMLibrary.root.appendingPathComponent(".creating", isDirectory: true) }
    public var logURL: URL { Self.directory.appendingPathComponent("\(name).log") }
    public var pidURL: URL { Self.directory.appendingPathComponent("\(name).pid") }

    /// The line the creating shell prints when `vitrinectl create…` returns.
    public static let exitMarker = "== create exited "

    // MARK: Validation

    /// Names end up in a file name, a DHCP host name and log paths.
    public static func isValidVMName(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil
    }

    /// Usernames are written into cloud-init shell commands and autounattend.xml, so only the
    /// portable POSIX subset; Windows' built-in account names are refused.
    public static func isValidUsername(_ s: String) -> Bool {
        guard s.range(of: #"^[a-z_][a-z0-9_-]{0,31}$"#, options: .regularExpression) != nil else { return false }
        return !["administrator", "guest", "defaultaccount", "wdagutilityaccount", "root"].contains(s.lowercased())
    }

    static func isValidSize(_ s: String) -> Bool {
        s.range(of: #"^[0-9]{1,6}(\.[0-9]{1,3})?[MGTmgt]?$"#, options: .regularExpression) != nil
    }

    /// 20 letters and digits with at least one of each kind Windows' complexity rule asks for.
    /// (The system random generator is cryptographically secure on Apple platforms.)
    public static func generatePassword() -> String {
        let upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ"), lower = Array("abcdefghijkmnopqrstuvwxyz"), digits = Array("23456789")
        let all = upper + lower + digits
        var chars = [upper.randomElement()!, lower.randomElement()!, digits.randomElement()!]
        while chars.count < 20 { chars.append(all.randomElement()!) }
        return String(chars.shuffled())
    }

    // MARK: Command line

    /// `vitrinectl` arguments for the request. The password never appears here: the creating
    /// process reads it from stdin (`--password-stdin`), so it stays out of `ps`.
    public static func arguments(for r: Request, windowsISO: URL?) throws -> [String] {
        guard isValidVMName(r.name) else {
            throw VitrineError.invalidConfig("VM names use letters, digits, '.', '-' and '_' (up to 64, starting with a letter or digit)")
        }
        guard isValidUsername(r.username) else {
            throw VitrineError.invalidConfig("usernames use lowercase letters, digits, '-' and '_' (up to 32), and not a built-in account name")
        }
        var args: [String]
        switch r.kind {
        case .debian:
            args = ["create-linux", r.name, "--distro", "debian-13"]
            if !r.desktop { args += ["--desktop", "no"] }
        case .windows:
            guard let iso = windowsISO else { throw VitrineError.invalidConfig("no Windows 11 ISO") }
            args = ["create-windows", r.name, "--iso", iso.path]
            if r.x64 { args += ["--arch", "x64"] }
        case .macOS:
            args = ["create", r.name, "--ipsw", r.image ?? "latest"]
        }
        if let n = r.cpus {
            guard (1...64).contains(n) else { throw VitrineError.invalidConfig("cpus must be 1–64") }
            args += ["--cpus", String(n)]
        }
        for (key, value) in [("memory", r.memory), ("disk", r.disk)] {
            guard let v = value else { continue }
            guard isValidSize(v) else { throw VitrineError.invalidConfig("\(key) looks like 8G or 8192M") }
            args += ["--\(key)", v]
        }
        return args + ["--user", r.username, "--password-stdin"]
    }

    /// The newest cached Windows 11 ISO for the architecture (`Windows11_*_arm64_*.iso` or `*_x64*`).
    public static func cachedWindowsISO(x64: Bool, in directory: URL = VMLibrary.cacheDirectory.appendingPathComponent("windows")) -> URL? {
        let marker = x64 ? "x64" : "arm64"
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return items
            .filter { $0.pathExtension.lowercased() == "iso" && $0.lastPathComponent.lowercased().hasPrefix("win")
                      && $0.lastPathComponent.lowercased().contains(marker) }
            .max { modified($0) < modified($1) }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    // MARK: Status

    /// What the job's log and process say, and whether the VM exists and runs.
    public func status(bundle: VMBundle?, lines: Int = 12) -> Status {
        let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let exit = Self.exitCode(in: text)
        let tail = Self.summarize(text, lines: lines)
        let alive = processAlive()
        let state: State
        if let code = exit, code != 0 { state = .failed }
        else if bundle?.runningPID() != nil { state = .running }
        else if exit == 0, bundle != nil { state = .created }
        else if alive { state = .creating }
        else if !text.isEmpty { state = .failed } // the process is gone without saying how it ended
        else { state = .unknown }
        return Status(state: state, exitCode: exit, log: tail)
    }

    static func exitCode(in log: String) -> Int32? {
        guard let line = log.components(separatedBy: "\n").last(where: { $0.hasPrefix(exitMarker) }) else { return nil }
        return Int32(line.dropFirst(exitMarker.count).trimmingCharacters(in: .whitespaces))
    }

    /// The last `lines` lines of a log, with progress bars (redrawn with carriage returns) reduced
    /// to their latest state and blank lines dropped.
    public static func summarize(_ log: String, lines: Int) -> [String] {
        let kept = log.components(separatedBy: "\n").compactMap { line -> String? in
            let latest = line.components(separatedBy: "\r").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            return latest?.trimmingCharacters(in: .whitespaces)
        }
        return Array(kept.suffix(lines))
    }

    func processAlive() -> Bool {
        guard let s = try? String(contentsOf: pidURL, encoding: .utf8), let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Clears an earlier job's files and records a new process.
    public func begin(pid: pid_t) throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try Data("\(pid)\n".utf8).write(to: pidURL, options: .atomic)
    }

    public func reset() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: logURL)
        try? FileManager.default.removeItem(at: pidURL)
    }

    /// A job still at work (its process alive), whatever its log says so far.
    public var isActive: Bool { processAlive() && Self.exitCode(in: (try? String(contentsOf: logURL, encoding: .utf8)) ?? "") == nil }

    /// The shell that runs the creation, prints the exit marker and then, if asked, becomes the
    /// VM's runner. `$0` is vitrinectl, `$1` the VM to start afterwards ("" for none), the rest
    /// the create arguments. stdin (the password) goes to the create command.
    public static let shellScript = """
    start="$1"; shift; "$0" "$@"; rc=$?; echo "\(exitMarker)$rc"; \
    if [ "$rc" = 0 ] && [ -n "$start" ]; then echo "== starting $start"; exec "$0" run "$start"; fi; exit "$rc"
    """
}
