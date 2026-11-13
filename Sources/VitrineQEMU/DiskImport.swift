import Foundation
import VitrineCore

/// Brings disk images from other virtualization tools into Vitrine's format: `qemu-img` reads
/// qcow2, VMDK, VHD/VHDX, VDI, Parallels and raw, and writes a sparse raw image (both backends use
/// raw or ASIF; raw images are APFS-clonable, which snapshots and clones rely on).
public enum DiskImport {
    public struct Info: Sendable {
        public var format: String
        public var virtualSize: UInt64
        /// Other files the image reads from. An image from elsewhere can point these at any file
        /// on the Mac. Backing and external data files (never imported) …
        public var backingFiles: [String] = []
        /// … and a VMDK's extents (imported when they sit next to the image).
        public var extents: [String] = []
    }

    /// Lets another thread stop a running import: the `qemu-img` child is terminated and the call
    /// running it throws `VitrineError.cancelled`.
    public final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var process: Process?
        public init() {}
        public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        public func cancel() {
            lock.lock()
            cancelled = true
            let p = process
            lock.unlock()
            if let p, p.isRunning { p.terminate() }
        }
        /// Remembers `p` (already running) so `cancel` can stop it; false if already cancelled.
        func attach(_ p: Process?) -> Bool {
            lock.lock(); defer { lock.unlock() }
            process = p
            return !cancelled
        }
        public func check() throws { if isCancelled { throw VitrineError.cancelled } }
    }

    public static func qemuImg() throws -> URL {
        let url = try QEMUEnvironment.detect().binDirectory.appendingPathComponent("qemu-img")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw VitrineError.unsupported("qemu-img not found — install QEMU with `brew install qemu`")
        }
        return url
    }

    public static var isQemuImgAvailable: Bool { (try? qemuImg()) != nil }

    static func run(_ args: [String], cancellation: Cancellation? = nil) throws -> Data {
        let p = Process()
        p.executableURL = try qemuImg()
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try cancellation?.check()
        try p.run()
        if let cancellation, !cancellation.attach(p) { p.terminate() }
        defer { _ = cancellation?.attach(nil) }
        // Read both pipes at once: a child filling one while we block on the other would hang.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        if cancellation?.isCancelled == true { throw VitrineError.cancelled }
        guard p.terminationStatus == 0 else {
            let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw VitrineError.io("qemu-img \(args.first ?? ""): \(message.isEmpty ? "exit \(p.terminationStatus)" : message)")
        }
        return data
    }

    /// Format and virtual size of an image. With `format`, the image is opened as that format
    /// (`-f`) instead of probed: an imported VM's configuration says what its disks are, and a
    /// probe can be fooled (a Parallels `.hdd` probes as raw).
    public static func info(_ url: URL, format: String? = nil) throws -> Info {
        var args = ["info", "--output=json"]
        if let format { args += ["-f", format] }
        return try parseInfo(run(args + [url.path]), what: url.lastPathComponent)
    }

    /// `info` for a block-layer description (`blockSpec`).
    public static func info(spec: [String: Any]) throws -> Info {
        try parseInfo(run(["info", "--output=json", jsonFilename(spec)]), what: "the disk")
    }

    static func parseInfo(_ data: Data, what: String) throws -> Info {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let format = json["format"] as? String, let size = json["virtual-size"] as? NSNumber else {
            throw VitrineError.io("qemu-img could not describe \(what)")
        }
        var info = Info(format: format, virtualSize: size.uint64Value)
        (info.backingFiles, info.extents) = referencedFiles(json)
        return info
    }

    static func referencedFiles(_ json: [String: Any]) -> (backing: [String], extents: [String]) {
        var backing: [String] = []
        for key in ["backing-filename", "full-backing-filename"] {
            if let f = json[key] as? String { backing.append(f) }
        }
        let data = (json["format-specific"] as? [String: Any])?["data"] as? [String: Any] ?? [:]
        if let f = data["data-file"] as? String { backing.append(f) }
        let extents = (data["extents"] as? [[String: Any]] ?? []).compactMap { $0["filename"] as? String }
        return (backing, extents)
    }

    /// A QEMU block-layer description of an image of `format` in `file` (an absolute path), or of
    /// one stored inside `file` at `window` (an OVA member read in place).
    public static func blockSpec(file: URL, format: String, window: (offset: UInt64, size: UInt64)? = nil) -> [String: Any] {
        var proto: [String: Any] = ["driver": "file", "filename": file.standardizedFileURL.path]
        if let window {
            proto = ["driver": "raw", "offset": window.offset, "size": window.size, "file": proto]
        }
        return ["driver": format, "file": proto]
    }

    static func jsonFilename(_ spec: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: spec, options: [.sortedKeys])
        return "json:" + String(decoding: data, as: UTF8.self)
    }

    /// `length` bytes the guest sees at `offset` of the image `spec` describes (`virtualSize`
    /// long), read through `qemu-img dd` into a private temporary file. Read-only on the source.
    public static func read(spec: [String: Any], virtualSize: UInt64, offset: UInt64, length: Int,
                            cancellation: Cancellation? = nil) throws -> Data {
        guard offset < virtualSize, length > 0 else { return Data() }
        let size = min(UInt64(length), virtualSize - offset)
        let window: [String: Any] = ["driver": "raw", "offset": offset, "size": size, "file": spec]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-probe-\(UUID().uuidString)")
        guard mkdir(dir.path, 0o700) == 0 else { throw VitrineError.io("cannot create \(dir.path)") }
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("chunk.raw")
        // bs = the whole window, count = 1: `dd`'s skip= is unreliable in qemu-img, so the offset
        // lives in the raw window instead.
        _ = try run(["dd", "-O", "raw", "bs=\(size)", "count=1", "if=\(try jsonFilename(window))", "of=\(out.path)"],
                    cancellation: cancellation)
        return try Data(contentsOf: out)
    }

    /// Writes `source` as a sparse raw image at `destination` (which must not exist). Raw sources
    /// are APFS-cloned instead of copied. Images that read from other files are accepted only when
    /// those files are VMDK extents next to the image (inside `root`, when given); backing and data
    /// files are refused. With `format` the image is opened as that format, never probed.
    public static func convert(_ source: URL, to destination: URL, format: String? = nil, root: URL? = nil,
                               cancellation: Cancellation? = nil) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw VitrineError.io("\(destination.path) already exists") }
        let info = try info(source, format: format)
        try checkSelfContained(source, info, root: root)
        try cancellation?.check()
        if info.format == "raw" {
            let attrs = try fm.attributesOfItem(atPath: source.resolvingSymlinksInPath().path)
            guard attrs[.type] as? FileAttributeType == .typeRegular else {
                throw VitrineError.unsupported("\(source.lastPathComponent) isn't a regular file")
            }
            try DiskImage.clone(source, to: destination)
            return
        }
        do {
            _ = try run(["convert", "-f", info.format, "-O", "raw", "-S", "4k", source.path, destination.path],
                        cancellation: cancellation)
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    /// Refuses images that read from other files, except a VMDK's extents in the image's folder
    /// (or anywhere inside `root`, when given; the image itself must then be inside `root` too).
    public static func checkSelfContained(_ source: URL, _ info: Info, root: URL? = nil) throws {
        func refuse(_ file: String) -> Error {
            VitrineError.unsupported("\(source.lastPathComponent) reads from another file (\(file)); flatten it into a standalone image first (qemu-img convert)")
        }
        // `qemu-img info` doesn't look down a backing chain, so even a sibling backing file could
        // lead anywhere: none are accepted.
        if let file = info.backingFiles.first { throw refuse(file) }
        // Every path compared with symlinks resolved the same way (realpath).
        func real(_ url: URL) -> String { ImportPath.realPath(url.standardizedFileURL.path) ?? url.standardizedFileURL.path }
        let image = URL(fileURLWithPath: real(source))
        let folder: String
        if let root {
            guard ImportPath.contained(image, in: root) != nil else { throw refuse(image.path) }
            folder = real(root) + "/"
        } else {
            folder = image.deletingLastPathComponent().path + "/"
        }
        for file in info.extents {
            let url = URL(fileURLWithPath: real(file.hasPrefix("/") ? URL(fileURLWithPath: file)
                                                : image.deletingLastPathComponent().appendingPathComponent(file)))
            if url == image { continue } // a monolithic VMDK lists itself as its only extent
            guard info.format == "vmdk", url.path.hasPrefix(folder) else { throw refuse(file) }
        }
    }
}
