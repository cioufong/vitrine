import Foundation
import Security
import VitrineCore

/// Shared folders for Windows guests: Homebrew Samba, spawned by QEMU's user-mode network for each
/// guest connection to \\10.0.2.4 (a `guestfwd … cmd:` rule, the way QEMU's own `smb=` works).
///
/// Unlike `smb=`, which only offers guest access (refused by Windows 11 24H2+ unless insecure guest
/// logons are enabled and SMB signing is turned off), the server here has one account — the Mac
/// user's name with a random password made for this VM run — so the guest keeps its defaults. The
/// guest learns the password from the agent (`MountShares`); it never touches the disk image.
public final class SambaServer: @unchecked Sendable {
    /// Address the guest reaches the server at (inside QEMU's 10.0.2.0/24; .2 = host, .3 = DNS).
    public static let guestAddress = "10.0.2.4"
    /// SMB share name of the drag-and-drop folder.
    public static let transferShare = "VitrineTransfer"

    public struct Share: Equatable, Sendable {
        public var name: String
        public var path: String
        public var readOnly: Bool
        /// Drive letter the guest maps it to (nil: none, e.g. the transfer share).
        public var letter: String?
        public init(name: String, path: String, readOnly: Bool, letter: String? = nil) {
            self.name = name; self.path = path; self.readOnly = readOnly; self.letter = letter
        }
    }

    public let username: String
    public let password: String
    private let directory: URL
    private let smbd: URL
    private var confURL: URL { directory.appendingPathComponent("smb.conf") }

    /// Homebrew installs smbd under a non-standard name so it doesn't clash with macOS's own.
    public static func findSmbd() -> URL? {
        ["/opt/homebrew/sbin/samba-dot-org-smbd", "/usr/local/sbin/samba-dot-org-smbd"]
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func findPdbedit(near smbd: URL) -> URL? {
        let bin = smbd.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("bin/pdbedit")
        return FileManager.default.isExecutableFile(atPath: bin.path) ? bin : nil
    }

    /// Prepares a private Samba instance in `directory` (wiped first) with `shares`.
    public init(directory: URL, shares: [Share]) throws {
        guard let smbd = Self.findSmbd(), let pdbedit = Self.findPdbedit(near: smbd) else {
            throw VitrineError.unsupported("Windows shared folders need Samba: install it with `brew install samba`")
        }
        self.smbd = smbd
        self.directory = directory
        self.username = NSUserName()
        self.password = Self.randomPassword()
        let fm = FileManager.default
        try? fm.removeItem(at: directory)
        do {
            for sub in ["private", "state/ncalrpc"] {
                try fm.createDirectory(at: directory.appendingPathComponent(sub), withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try update(shares: shares)
            try addUser(pdbedit: pdbedit)
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    /// Rewrites the configuration. Each guest connection starts its own smbd, which reads it; the
    /// ones already serving the guest are told to reload it (SIGHUP), or a newly added share would
    /// be unknown to them ("network name cannot be found") until they happen to re-read it.
    public func update(shares: [Share]) throws {
        try Self.config(directory: directory, username: username, shares: shares)
            .write(to: confURL, atomically: true, encoding: .utf8)
        reloadRunning()
    }

    /// Regex for `pkill -f` matching exactly the smbd processes of one instance: their argv joined
    /// with spaces is "<smbd> -s <conf>"; QEMU's carries the same words but quoted ("'<smbd>' -s '<conf>'").
    static func reloadPattern(smbd: String, conf: String) -> String {
        "^" + NSRegularExpression.escapedPattern(for: "\(smbd) -s \(conf)") + "$"
    }

    private func reloadRunning() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        // Options before the pattern (BSD pkill treats anything after it as more patterns). The
        // pattern is smbd's own command line ("<smbd> -s <conf>"), not just the config path: QEMU's
        // command line contains the path too (in its guestfwd option, quoted), and SIGHUP would
        // terminate QEMU — the VM.
        p.arguments = ["-HUP", "-f", Self.reloadPattern(smbd: smbd.path, conf: confURL.path)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    /// The `guestfwd` command QEMU runs per connection (parsed shell-style by libslirp).
    public var command: String { "\(Self.quote(smbd.path)) -s \(Self.quote(confURL.path))" }

    static func config(directory: URL, username: String, shares: [Share]) throws -> String {
        let d = directory.path
        var conf = """
        [global]
        netbios name = VITRINE
        workgroup = VITRINE
        private dir = \(d)/private
        passdb backend = tdbsam:\(d)/private/passdb.tdb
        state directory = \(d)/state
        lock directory = \(d)/state
        cache directory = \(d)/state
        pid directory = \(d)/state
        ncalrpc dir = \(d)/state/ncalrpc
        log file = \(d)/smbd.log
        max log size = 1000
        security = user
        map to guest = never
        server min protocol = SMB2_10
        server signing = mandatory
        load printers = no
        printing = bsd
        disable spoolss = yes
        disable netbios = yes
        usershare max shares = 0
        ea support = no
        store dos attributes = no

        """
        for s in shares {
            guard VMConfig.SharedDirectory.isValidSMBName(s.name) else { throw VitrineError.invalidConfig("invalid SMB share name \"\(s.name)\"") }
            guard !s.path.contains(where: \.isNewline) else { throw VitrineError.invalidConfig("invalid share path") }
            // smbd expands %-macros in paths (%U, %D, …) and has no escape for a literal %.
            guard Self.isServablePath(s.path) else {
                throw VitrineError.invalidConfig("Samba can't share a folder whose path contains \"%\": \(s.path)")
            }
            conf += """
            [\(s.name)]
            path = \(s.path)
            read only = \(s.readOnly ? "yes" : "no")
            valid users = \(username)
            browseable = yes

            """
        }
        return conf
    }

    /// A name a user's shared folder can have (the drag-and-drop share's name is taken).
    public static func isValidShareName(_ name: String) -> Bool {
        VMConfig.SharedDirectory.isValidSMBName(name) && !VMConfig.SharedDirectory.isReservedSMBName(name)
    }

    /// Paths smb.conf can carry unchanged: smbd expands %-macros (no escape exists), trims
    /// surrounding whitespace and treats a trailing backslash as a line continuation.
    public static func isServablePath(_ path: String) -> Bool {
        !path.contains("%") && !path.contains(where: \.isNewline) && !path.hasSuffix("\\")
            && path.trimmingCharacters(in: .whitespaces) == path
    }

    /// Removes the instance directory (its passdb holds the hash of this run's password).
    public func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func addUser(pdbedit: URL) throws {
        let p = Process()
        p.executableURL = pdbedit
        p.arguments = ["-s", confURL.path, "-a", "-u", username, "-t"]
        let input = Pipe()
        p.standardInput = input
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        try p.run()
        input.fileHandleForWriting.write(Data("\(password)\n\(password)\n".utf8))
        try input.fileHandleForWriting.close()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw VitrineError.backend("could not set up the Samba account: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func randomPassword() -> String {
        var rng = SystemRandomNumberGenerator() // kernel CSPRNG on Darwin; unlike SecRandomCopyBytes it can't fail
        let bytes = (0..<18).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "A").replacingOccurrences(of: "/", with: "b")
    }
}
