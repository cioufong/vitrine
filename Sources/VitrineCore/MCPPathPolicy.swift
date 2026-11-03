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

    static func isInside(_ path: String, _ root: String) -> Bool {
        // APFS volumes are case-insensitive by default.
        let p = path.lowercased(), r = root.lowercased()
        return p == r || p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }

    public func allowList() -> [String] {
        guard let text = try? String(contentsOf: allowListURL, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }.map { Self.resolve($0) }
    }

    /// The protected root `path` falls in, or nil when the tools may use it. For a folder, also
    /// every symlink inside it (scp -r copies what they point to).
    public func protectedRoot(for path: String) -> String? {
        let allowed = allowList()
        let roots = protectedRoots
        func check(_ resolved: String) -> String? {
            guard let root = roots.first(where: { Self.isInside(resolved, $0) }) else { return nil }
            return allowed.contains(where: { Self.isInside(resolved, $0) }) ? nil : root
        }
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
