import Foundation
import VitrineCore

/// Plain resumable-enough download for QEMU-side assets (driver ISOs). Uses URLSession's download task
/// and moves the file into place atomically.
public enum QEMUDownload {
    public static func download(_ url: URL, to dest: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let delegate = ProgressDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (tmp, response) = try await session.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { throw VitrineError.io("download failed: \(url)") }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @Sendable (Double) -> Void
        init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
        }
    }
}
