import Foundation

/// Which Mac paths the MCP server's file tools (`push_file`, `pull_file`, `create_vm`'s `image`)
/// may touch. Everything is allowed except a set of protected locations: secrets (the VM library
/// with its guest passwords, SSH and cloud credentials, keychains) and places where a written
/// file runs code later (launch agents, shell startup files, AI agents' own settings). A protected
/// path is allowed when the user lists it with `vitrinectl mcp allow PATH`, or when they approve it
/// in the MCP client (elicitation) for one call.
public struct MCPPathPolicy: Sendable {
    public let home: URL
    public let libraryRoot: URL
    public let allowListURL: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                libraryRoot: URL = VMLibrary.root,
                allowListURL: URL = MCPPathPolicy.defaultAllowListURL) {
        self.home = home
        self.libraryRoot = libraryRoot
        self.allowListURL = allowListURL
    }

    /// Inside Vitrine's own support folder, itself protected, so `pull_file` cannot add to it.
    public static var defaultAllowListURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vitrine/mcp-allowed-paths")
    }

    static let homeRelative = [
        "Library/Application Support/Vitrine", "Library/Keychains", "Library/LaunchAgents", "Library/Cookies",
        "Library/Application Support/com.apple.TCC", "Library/Containers/com.apple.mail",
        ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".netrc", ".git-credentials", ".npmrc", ".pypirc",
        ".config/gh", ".config/gcloud", ".config/fish", ".config/git", ".gitconfig",
        ".zshrc", ".zprofile", ".zshenv", ".zlogin", ".zlogout", ".bashrc", ".bash_profile", ".profile", ".bash_login",
        ".claude", ".claude.json", ".codex", ".cursor", ".gemini", ".config/claude", ".mcp.json",
    ]
    /// System locations are writable only by root anyway; these two would still run what lands there.
    static let absolute = ["/Library/LaunchAgents", "/Library/LaunchDaemons"]

    /// Protected roots, resolved (so a root reached through a symlink still matches).
    public var protectedRoots: [String] {
        let roots = Self.homeRelative.map { home.appendingPathComponent($0).path } + Self.absolute + [libraryRoot.path]
        return roots.map { Self.resolve($0) }
    }

    /// The path with symlinks resolved; a path that doesn't exist yet (a pull destination) is
    /// resolved through its deepest existing ancestor.
    public static func resolve(_ path: String) -> String {
        var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            rest.insert(url.lastPathComponent, at: 0)
            url.deleteLastPathComponent()
        }
        var resolved = url.resolvingSymlinksInPath()
        for c in rest { resolved.appendPathComponent(c) }
        return resolved.standardizedFileURL.path
    }

    public static func isInside(_ path: String, _ root: String) -> Bool {
        // APFS volumes are case-insensitive by default.
        let p = path.lowercased(), r = root.lowercased()
        return p == r || p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }

    public func allowList() -> [String] {
        guard let text = try? String(contentsOf: allowListURL, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }.map { Self.resolve($0) }
    }

    /// The protected root `resolved` falls in or contains, or nil when it is allowed. A folder that
    /// holds a protected root (`~`, `~/Library`, `/`) counts as protected: scp -r would copy all of
    /// it, and pulling into it could write anywhere below. The allow list opens a path and what is
    /// below it, so allowing `~/.ssh` doesn't open `~`, which still holds the other roots.
    static func check(_ resolved: String, allowed: [String], roots: [String]) -> String? {
        if allowed.contains(where: { isInside(resolved, $0) }) { return nil }
        if let root = roots.first(where: { isInside(resolved, $0) }) { return root }
        return roots.first { root in isInside(root, resolved) && !allowed.contains { isInside(root, $0) } }
    }

    /// The protected root `path` falls in or contains, or nil when the tools may use it. For a
    /// folder, also every symlink inside it (scp -r copies what they point to).
    public func protectedRoot(for path: String) -> String? {
        let allowed = allowList()
        let roots = protectedRoots
        func check(_ resolved: String) -> String? { Self.check(resolved, allowed: allowed, roots: roots) }
        let resolved = Self.resolve(path)
        if let root = check(resolved) { return root }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue,
              let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: resolved),
                                                          includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return nil }
        for case let item as URL in walker {
            guard (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else { continue }
            if let root = check(Self.resolve(item.path)) { return root }
        }
        return nil
    }

    /// The protected root a file written at `path` would land in (through symlinks already on the
    /// Mac) or that `path` contains; only the path itself is checked, not what is below it.
    public func protectedRoot(forDestination path: String) -> String? {
        Self.check(Self.resolve(path), allowed: allowList(), roots: protectedRoots)
    }

    // MARK: pull_file

    /// One item `pull_file` downloaded: where scp put it in the staging folder, where it goes on
    /// the Mac, and the protected root that destination falls in or contains (nil: it may be written).
    public struct Placement: Sendable {
        public let source: URL
        public let destination: URL
        public let protectedRoot: String?
    }

    /// Plans moving what scp downloaded into `staging` (a fresh private folder) to `local`, by
    /// scp's rules: into `local` when it is a folder, else as `local` (one item only). Every file
    /// and folder gets its final destination checked, through symlinks already on the Mac. A
    /// symlink in the download is refused unless it is relative without `..` (so it, and any chain
    /// of such links, stays inside what was downloaded).
    public func planDownload(staging: URL, to local: URL) throws -> [Placement] {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(atPath: staging.path).sorted()
        var isDir: ObjCBool = false
        let intoFolder = fm.fileExists(atPath: local.path, isDirectory: &isDir) && isDir.boolValue
        guard intoFolder || entries.count == 1 else {
            throw VitrineError.invalidConfig(entries.isEmpty ? "the guest sent nothing"
                : "\(local.path) is not a folder, and the guest path matched \(entries.count) items")
        }
        let allowed = allowList(), roots = protectedRoots
        var plan: [Placement] = []
        for entry in entries {
            let source = staging.appendingPathComponent(entry)
            let destination = intoFolder ? local.appendingPathComponent(entry) : local
            // Pre-order (a folder before what is in it); symlinked folders are not descended into.
            let below = fm.enumerator(atPath: source.path)?.compactMap { $0 as? String } ?? []
            for rel in [""] + below {
                let from = rel.isEmpty ? source : source.appendingPathComponent(rel)
                let to = rel.isEmpty ? destination : destination.appendingPathComponent(rel)
                if let target = try? fm.destinationOfSymbolicLink(atPath: from.path),
                   target.hasPrefix("/") || target.split(separator: "/").contains("..") {
                    throw VitrineError.invalidConfig("the guest sent a symlink, \(rel.isEmpty ? entry : entry + "/" + rel) -> \(target), that points outside what was copied")
                }
                plan.append(Placement(source: from, destination: to,
                                      protectedRoot: Self.check(Self.resolve(to.path), allowed: allowed, roots: roots)))
            }
        }
        return plan
    }

    /// The placements still protected when the user approved writing to `approved` (resolved): one
    /// below it is covered only when `approved` lies within that placement's protected root, so
    /// approving `~/.ssh` doesn't cover `~/.zshrc`, and an approved ancestor covers none of the roots in it.
    public static func needingApproval(_ plan: [Placement], approved: String?) -> [Placement] {
        plan.filter { p in
            guard let root = p.protectedRoot else { return false }
            guard let approved else { return true }
            return !(isInside(resolve(p.destination.path), approved) && isInside(approved, root))
        }
    }

    /// Moves a planned download into place: folders are created or merged into, files and symlinks
    /// replace what is there (as scp would; a symlink there is replaced, not written through).
    /// A destination that was allowed when planned is checked again just before it is written,
    /// in case a symlink appeared in the meantime.
    public func place(_ plan: [Placement]) throws {
        let fm = FileManager.default
        let allowed = allowList(), roots = protectedRoots
        // Folders get the guest's mode once filled: a read-only one couldn't take its contents.
        var modes: [(URL, Any)] = []
        defer { for (url, mode) in modes.reversed() { try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) } }
        for p in plan {
            if p.protectedRoot == nil, let root = Self.check(Self.resolve(p.destination.path), allowed: allowed, roots: roots) {
                throw VitrineError.invalidConfig("\(p.destination.path) is now in a protected location (\(root))")
            }
            let attrs = try fm.attributesOfItem(atPath: p.source.path)
            let existing = try? fm.attributesOfItem(atPath: p.destination.path)  // not following a symlink
            if attrs[.type] as? FileAttributeType == .typeDirectory {
                // The staging copy too, so what is in it can be moved out (and the folder deleted).
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: p.source.path)
                if existing == nil {
                    try fm.createDirectory(at: p.destination, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
                    modes.append((p.destination, attrs[.posixPermissions] ?? 0o755))
                } else {
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: p.destination.path, isDirectory: &isDir), isDir.boolValue else {
                        throw VitrineError.invalidConfig("\(p.destination.path) exists and is not a folder")
                    }
                }
            } else {
                if let existing {
                    guard existing[.type] as? FileAttributeType != .typeDirectory else {
                        throw VitrineError.invalidConfig("\(p.destination.path) is a folder")
                    }
                    try fm.removeItem(at: p.destination)
                }
                try fm.moveItem(at: p.source, to: p.destination)
            }
        }
    }

    /// Adds or removes a path in the allow list (for `vitrinectl mcp allow|disallow`).
    public func setAllowed(_ path: String, _ allowed: Bool) throws {
        let resolved = Self.resolve(path)
        var lines = (try? String(contentsOf: allowListURL, encoding: .utf8))?
            .split(whereSeparator: \.isNewline).map(String.init) ?? []
        lines.removeAll { Self.resolve($0.trimmingCharacters(in: .whitespaces)) == resolved }
        if allowed { lines.append(resolved) }
        try FileManager.default.createDirectory(at: allowListURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: allowListURL, atomically: true, encoding: .utf8)
    }
}
