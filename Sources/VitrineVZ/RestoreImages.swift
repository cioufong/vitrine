import Foundation
import Virtualization
import VitrineCore
import CryptoKit
import Darwin

/// Locates and downloads macOS restore images (IPSW).
public enum RestoreImages {
    public struct Info: Sendable {
        public var url: URL
        public var buildVersion: String
        public var osVersion: String
    }

    /// Latest IPSW this host can install (from Apple's catalog).
    public static func latestSupported() async throws -> Info {
        let image: VZMacOSRestoreImage = try await withCheckedThrowingContinuation { cont in
            VZMacOSRestoreImage.fetchLatestSupported { cont.resume(with: $0) }
        }
        let v = image.operatingSystemVersion
        return Info(url: image.url, buildVersion: image.buildVersion,
                    osVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
    }

    public static func load(_ fileURL: URL) async throws -> VZMacOSRestoreImage {
        try await withCheckedThrowingContinuation { cont in
            VZMacOSRestoreImage.load(from: fileURL) { cont.resume(with: $0) }
        }
    }

    /// Cache path for a remote IPSW.
    public static func cachedPath(for remote: URL) -> URL {
        cachePath(for: remote, subdirectory: "ipsw")
    }

    private static func cachePath(for remote: URL, subdirectory: String) -> URL {
        let source = SHA256.hash(data: Data(remote.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return VMLibrary.cacheDirectory.appendingPathComponent(subdirectory, isDirectory: true)
            .appendingPathComponent(source, isDirectory: true).appendingPathComponent(remote.lastPathComponent)
    }

    /// Downloads `remote` into the cache (skipping if complete), reporting progress 0…1.
    public static func download(_ remote: URL, progress: @escaping @Sendable (Double, Int64, Int64) -> Void) async throws -> URL {
        try await downloadToCache(remote, subdirectory: "ipsw", progress: progress)
    }

    /// Resumable download into `<cache>/<subdirectory>/<file name>`; returns immediately if complete.
    public static func downloadToCache(_ remote: URL, subdirectory: String,
                                       progress: @escaping @Sendable (Double, Int64, Int64) -> Void) async throws -> URL {
        guard !remote.lastPathComponent.isEmpty, remote.lastPathComponent != ".", remote.lastPathComponent != ".." else {
            throw VitrineError.invalidConfig("download URL requires an image filename")
        }
        // A basename alone is not an identity: different remote images often use the same name.
        // Legacy flat caches remain untouched rather than being trusted without source provenance.
        let dest = cachePath(for: remote, subdirectory: subdirectory)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lease = try DownloadLease(directory: dest.deletingLastPathComponent())
        defer { lease.release() }
        if FileManager.default.fileExists(atPath: dest.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: dest.path)
            if (attributes[.size] as? NSNumber)?.uint64Value ?? 0 > 0 { return dest }
            // Older builds could promote HTTP 204 to an empty completed image.
            try FileManager.default.removeItem(at: dest)
        }
        let partial = dest.appendingPathExtension("part")
        try await ResumableDownloader(remote: remote, partial: partial, progress: progress).run()
        try FileManager.default.moveItem(at: partial, to: dest)
        try? FileManager.default.removeItem(at: partial.appendingPathExtension("http.json"))
        return dest
    }
}

/// Owns both the partial file and promotion into the completed cache, across tasks and processes.
private final class DownloadLease {
    private var fd: Int32
    init(directory: URL) throws {
        // Keep ownership outside the payload directory so no remote basename can alias it.
        let path = directory.deletingLastPathComponent()
            .appendingPathComponent(".\(directory.lastPathComponent).lock").path
        fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw VitrineError.io("cannot open download ownership lock") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); fd = -1
            throw VitrineError.backend("this image download is already in progress; wait for it to finish and retry")
        }
    }
    func release() { if fd >= 0 { close(fd); fd = -1 } }
    deinit { release() }
}
