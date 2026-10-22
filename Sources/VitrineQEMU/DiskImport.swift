import Foundation
import VitrineCore

/// Brings disk images from other virtualization tools into Vitrine's format: `qemu-img` reads
/// qcow2, VMDK, VHD/VHDX, VDI and raw, and writes a sparse raw image (both backends use raw or
/// ASIF; raw images are APFS-clonable, which snapshots and clones rely on).
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

    static func qemuImg() throws -> URL {
        let url = try QEMUEnvironment.detect().binDirectory.appendingPathComponent("qemu-img")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw VitrineError.unsupported("qemu-img not found — install QEMU with `brew install qemu`")
        }
        return url
    }

    static func run(_ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = try qemuImg()
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw VitrineError.io("qemu-img \(args.first ?? ""): \(message.isEmpty ? "exit \(p.terminationStatus)" : message)")
        }
        return data
    }

    /// Format and virtual size of an image.
    public static func info(_ url: URL) throws -> Info {
        let data = try run(["info", "--output=json", url.path])
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let format = json["format"] as? String, let size = json["virtual-size"] as? NSNumber else {
            throw VitrineError.io("qemu-img could not describe \(url.lastPathComponent)")
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

    /// Writes `source` as a sparse raw image at `destination` (which must not exist). Raw sources
    /// are APFS-cloned instead of copied. Images that read from other files are accepted only when
    /// those files are VMDK extents next to the image; backing and data files are refused.
    public static func convert(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw VitrineError.io("\(destination.path) already exists") }
        let info = try info(source)
        try checkSelfContained(source, info)
        if info.format == "raw" {
            try DiskImage.clone(source, to: destination)
            return
        }
        do {
            _ = try run(["convert", "-f", info.format, "-O", "raw", "-S", "4k", source.path, destination.path])
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    static func checkSelfContained(_ source: URL, _ info: Info) throws {
        func refuse(_ file: String) -> Error {
            VitrineError.unsupported("\(source.lastPathComponent) reads from another file (\(file)); flatten it into a standalone image first (qemu-img convert)")
        }
        // `qemu-img info` doesn't look down a backing chain, so even a sibling backing file could
        // lead anywhere: none are accepted.
        if let file = info.backingFiles.first { throw refuse(file) }
        let image = source.resolvingSymlinksInPath().standardizedFileURL
        let folder = image.deletingLastPathComponent().path + "/"
        for file in info.extents {
            let url = (file.hasPrefix("/") ? URL(fileURLWithPath: file)
                       : image.deletingLastPathComponent().appendingPathComponent(file))
                .resolvingSymlinksInPath().standardizedFileURL
            if url == image { continue } // a monolithic VMDK lists itself as its only extent
            guard info.format == "vmdk", url.path.hasPrefix(folder) else { throw refuse(file) }
        }
    }
}
