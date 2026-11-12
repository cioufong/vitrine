import Foundation

/// What importing a whole VM from another tool (OVA/OVF, VMware, Parallels, VirtualBox) would do,
/// worked out without writing anything. `blockers` empty means `execute` may run; `warnings` are
/// things the user should know (settings raised or dropped, slow emulation, …).
public struct ImportPlan: Codable, Sendable, Equatable {
    public enum SourceFormat: String, Codable, Sendable, CaseIterable {
        case ova, ovf, vmware, parallels, virtualBox

        public var displayName: String {
            switch self {
            case .ova: return "OVA"
            case .ovf: return "OVF"
            case .vmware: return "VMware"
            case .parallels: return "Parallels Desktop"
            case .virtualBox: return "VirtualBox"
            }
        }
    }

    /// One reason not to import, or one thing to know about the import. `code` is stable (for the
    /// app to pick an icon or a help link); `message` is English prose for the user.
    public struct Issue: Codable, Sendable, Equatable, CustomStringConvertible {
        public enum Code: String, Codable, Sendable {
            // Blockers
            case pathOutsideSource, diskMissing, diskFormat, noDisks, snapshots, savedState, encrypted,
                 running, biosOnly, noBootPartition, macOSGuest, unsupportedArchitecture, archive,
                 manifest, multipleVMs, unreadableConfig, physicalDisk, qemuMissing, invalidName
            // Warnings
            case nameChanged, nameTaken, cpusReduced, cpusMissing, memoryRaised, memoryReduced,
                 memoryMissing, macReplaced, emulated, firmwareConfig, noFallbackLoader, nvramNotImported,
                 tpmNotImported, mediaSkipped, guestOSAssumed, architectureFromDisk, signatureNotChecked,
                 networkDrivers, cleanShutdown, basicDisplay, other
        }
        public var code: Code
        public var message: String
        public init(_ code: Code, _ message: String) { self.code = code; self.message = message }
        public var description: String { message }
    }

    /// A file inside an archive (OVA), read in place by inspection and copied out by `execute`.
    public struct ArchiveMember: Codable, Sendable, Equatable {
        public var name: String
        /// Offset of the member's data in the archive, and its length.
        public var offset: UInt64
        public var size: UInt64
        /// Expected digest from the package's manifest, if it has one.
        public var digest: Digest?
        public init(name: String, offset: UInt64, size: UInt64, digest: Digest? = nil) {
            self.name = name; self.offset = offset; self.size = size; self.digest = digest
        }
    }

    public struct Digest: Codable, Sendable, Equatable {
        public enum Algorithm: String, Codable, Sendable { case sha1, sha256, sha512 }
        public var algorithm: Algorithm
        /// Lowercase hex.
        public var hex: String
        public init(algorithm: Algorithm, hex: String) { self.algorithm = algorithm; self.hex = hex.lowercased() }
    }

    public struct Disk: Codable, Sendable, Equatable {
        /// The image file, symlinks resolved and inside `sourceRoot` (or, for an OVA member, the archive).
        public var file: URL
        public var member: ArchiveMember?
        /// The format the source declares, as a `qemu-img` format name (vmdk, parallels, vdi, vpc,
        /// qcow2, raw). Conversion is told this format rather than probing the file.
        public var format: String
        /// Bytes the guest sees, when known.
        public var virtualSize: UInt64?
        /// Where the source attaches it, e.g. "sata0:0" or "harddisk1.hdd" (for messages).
        public var label: String
        public var readOnly: Bool = false
        public init(file: URL, member: ArchiveMember? = nil, format: String, virtualSize: UInt64? = nil,
                    label: String, readOnly: Bool = false) {
            self.file = file; self.member = member; self.format = format; self.virtualSize = virtualSize
            self.label = label; self.readOnly = readOnly
        }
    }

    public enum Firmware: String, Codable, Sendable { case uefi, bios, unknown }

    public var format: SourceFormat
    /// What the user pointed at (a file or a bundle folder).
    public var source: URL
    /// Every file the import reads must be inside this folder (symlinks resolved).
    public var sourceRoot: URL
    /// The VM's name in the source, as written there.
    public var sourceName: String?
    /// A valid Vitrine VM name derived from `sourceName` (see `VMImportName.sanitize`).
    public var name: String
    public var guestOS: VMConfig.GuestOS = .linux
    public var architecture: VMConfig.Architecture = .aarch64
    public var backend: VMConfig.Backend = .vz
    /// Boot firmware the disk needs (from its partition table), and what the source's config says.
    public var firmware: Firmware = .unknown
    public var configuredFirmware: String?
    /// Partition table and boot loaders found on the boot disk, for display.
    public var bootDisk: BootDiskProbe.Result?
    public var cpuCount: Int
    public var memoryMiB: UInt64
    public var disks: [Disk] = []
    /// Normalised ("aa:bb:cc:dd:ee:ff") MAC of the first network adapter, when the source's is valid.
    public var macAddress: String?
    /// The source had no (enabled) network adapter.
    public var networkDisabled = false
    public var warnings: [Issue] = []
    public var blockers: [Issue] = []

    public var canImport: Bool { blockers.isEmpty }

    public init(format: SourceFormat, source: URL, sourceRoot: URL, name: String, cpuCount: Int, memoryMiB: UInt64) {
        self.format = format; self.source = source; self.sourceRoot = sourceRoot; self.name = name
        self.cpuCount = cpuCount; self.memoryMiB = memoryMiB
    }

    public mutating func block(_ code: Issue.Code, _ message: String) {
        let issue = Issue(code, message)
        if !blockers.contains(issue) { blockers.append(issue) }
    }

    public mutating func warn(_ code: Issue.Code, _ message: String) {
        let issue = Issue(code, message)
        if !warnings.contains(issue) { warnings.append(issue) }
    }

    /// A human-readable summary (what `vitrinectl import --dry-run` prints).
    public var summary: String {
        var lines: [String] = []
        lines.append("source:   \(format.displayName) — \(source.path)")
        lines.append("name:     \(name)" + (sourceName.map { $0 == name ? "" : " (was \($0.debugDescription))" } ?? ""))
        let engine = backend == .vz ? "Virtualization.framework" : (architecture == .x86_64 ? "QEMU (emulated x86_64)" : "QEMU")
        lines.append("guest:    \(guestOS.rawValue), \(architecture.rawValue) → \(engine)")
        var fw = firmware == .uefi ? "UEFI" : firmware == .bios ? "BIOS only" : "unknown"
        if let b = bootDisk { fw += " (\(b.summary))" }
        if let c = configuredFirmware { fw += "; source config says \(c)" }
        lines.append("firmware: \(fw)")
        lines.append("cpus:     \(cpuCount)")
        lines.append("memory:   \(memoryMiB) MiB")
        for (i, d) in disks.enumerated() {
            let size = d.virtualSize.map { " " + ImportPlan.formatBytes($0) } ?? ""
            let where_ = d.member.map { "\(d.file.lastPathComponent):\($0.name)" } ?? d.file.path
            lines.append("disk \(i + 1):   \(where_) [\(d.format)\(size)] (\(d.label))\(d.readOnly ? " read-only" : "")")
        }
        lines.append("network:  " + (networkDisabled ? "none" : "NAT, MAC \(macAddress ?? "new random")"))
        for w in warnings { lines.append("warning:  \(w.message)") }
        for b in blockers { lines.append("BLOCKED:  \(b.message)") }
        lines.append(blockers.isEmpty ? "result:   can be imported" : "result:   cannot be imported (\(blockers.count) blocker\(blockers.count == 1 ? "" : "s"))")
        return lines.joined(separator: "\n")
    }

    public static func formatBytes(_ n: UInt64) -> String {
        let gib = Double(n) / Double(1 << 30)
        return gib >= 1 ? String(format: "%.1f GiB", gib) : String(format: "%.0f MiB", Double(n) / Double(1 << 20))
    }
}

/// Turning other tools' VM names into Vitrine VM names (`VMCreationJob.isValidVMName`: they end up
/// in a bundle path, a DHCP host name and log paths).
public enum VMImportName {
    /// A valid VM name resembling `raw`: runs of other characters become "-", leading characters
    /// that aren't letters or digits are dropped, at most 64 characters. "Imported-VM" when nothing
    /// usable is left (a name in another script, say).
    public static func sanitize(_ raw: String) -> String {
        var out = ""
        var pendingDash = false
        for ch in raw.unicodeScalars {
            let ok = ch.isASCII && (CharacterSet.alphanumerics.contains(ch) || ch == "." || ch == "-" || ch == "_")
            if ok {
                if pendingDash && !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(ch)
            } else {
                pendingDash = true
            }
        }
        while let f = out.unicodeScalars.first, !(f.isASCII && CharacterSet.alphanumerics.contains(f)) { out.removeFirst() }
        out = String(out.prefix(64))
        while let l = out.last, l == "-" || l == "." { out.removeLast() }
        // ".." and similar can't survive (they'd start with a dot), but check the result anyway.
        return VMCreationJob.isValidVMName(out) ? out : "Imported-VM"
    }

    /// `explicit` if given (it must already be valid: an explicit name is never silently changed),
    /// else `sanitize(derived)`.
    public static func resolve(explicit: String?, derived: String) throws -> String {
        if let explicit {
            guard VMCreationJob.isValidVMName(explicit) else {
                throw VitrineError.invalidConfig("\(explicit.debugDescription) is not a valid VM name (letters, digits, '.', '-' and '_', up to 64, starting with a letter or digit)")
            }
            return explicit
        }
        return sanitize(derived)
    }
}

/// Resolving file references found in another tool's VM configuration, refusing any that would
/// leave the VM's own folder.
public enum ImportPath {
    /// `reference` (relative to `base`, a folder inside `root`) as a file URL inside `root`, symlinks
    /// resolved; nil when it contains "..", a NUL, a drive letter, a URL or a backslash path that
    /// escapes, or resolves outside `root`. An absolute path is accepted only if it points inside
    /// `root` (VMware sometimes records its own folder's disks that way). Backslashes are taken as
    /// separators (Windows hosts write them).
    public static func resolve(_ reference: String, base: URL, root: URL) -> URL? {
        guard !reference.isEmpty, !reference.contains("\0") else { return nil }
        let normalized = reference.replacingOccurrences(of: "\\", with: "/")
        if normalized.hasPrefix("~") || normalized.hasPrefix("//") { return nil }
        // C:/…, file: URLs
        if normalized.range(of: #"^[A-Za-z]:"#, options: .regularExpression) != nil || normalized.contains("://") { return nil }
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        var url = normalized.hasPrefix("/") ? URL(fileURLWithPath: "/") : base
        for p in parts where p != "." { url.appendPathComponent(String(p)) }
        return contained(url, in: root)
    }

    /// `url` with symlinks resolved, if it is (strictly) inside `root` (also resolved).
    public static func contained(_ url: URL, in root: URL) -> URL? {
        guard let r = realPath(root.standardizedFileURL.path), let u = realPath(url.standardizedFileURL.path) else { return nil }
        guard u.hasPrefix(r.hasSuffix("/") ? r : r + "/") else { return nil }
        return URL(fileURLWithPath: u)
    }

    /// `path` with every symlink resolved, also when its last components don't exist yet (Foundation's
    /// resolvingSymlinksInPath gives up on those, leaving a symlinked folder above them unresolved).
    public static func realPath(_ path: String) -> String? {
        if let p = realpath(path, nil) { defer { free(p) }; return String(cString: p) }
        guard errno == ENOENT || errno == ENOTDIR else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        guard parent != path, !parent.isEmpty, let base = realPath(parent) else { return nil }
        let last = (path as NSString).lastPathComponent
        guard last != "..", last != "." else { return nil }
        return (base as NSString).appendingPathComponent(last)
    }
}
