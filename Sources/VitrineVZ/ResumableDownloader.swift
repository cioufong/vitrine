import Foundation
import VitrineCore

/// A partial image is reusable only with the same URL and a strong entity validator. Servers
/// without one are downloaded from byte zero on retry rather than mixing versions of an image.
final class ResumableDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct ResumeInfo: Codable {
        var remote: String
        var etag: String
        var total: Int64?
    }
    private struct IntegrityError: LocalizedError {
        let errorDescription: String?
        init(_ description: String) { errorDescription = description }
    }

    let remote: URL
    let partial: URL
    let progress: @Sendable (Double, Int64, Int64) -> Void
    private var metadataURL: URL { partial.appendingPathExtension("http.json") }
    // Delegate callbacks are serialized by URLSession; one attempt finishes before the next starts.
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var expected: Int64 = 0
    private var offset: Int64 = 0
    private var resumeInfo: ResumeInfo?
    private var acceptedResponse = false
    private var responseError: Error?
    private var continuation: CheckedContinuation<Void, Error>?
    private var lastReport = Date.distantPast

    init(remote: URL, partial: URL, progress: @escaping @Sendable (Double, Int64, Int64) -> Void) {
        self.remote = remote; self.partial = partial; self.progress = progress
    }

    func run() async throws {
        for attempt in 1...5 {
            try Task.checkCancellation()
            do { try await once(); return } catch {
                if error is IntegrityError || error is CancellationError || attempt == 5
                    || (error as? URLError)?.code == .cancelled { throw error }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
            }
        }
    }

    private func once() async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: partial.path) {
            guard fm.createFile(atPath: partial.path, contents: nil) else {
                throw VitrineError.io("cannot create partial download")
            }
        }
        let h = try FileHandle(forWritingTo: partial)
        handle = h
        defer { try? h.close(); handle = nil }
        let size = Int64(try h.seekToEnd())
        resumeInfo = (try? Data(contentsOf: metadataURL)).flatMap { try? JSONDecoder().decode(ResumeInfo.self, from: $0) }
        if let info = resumeInfo, info.remote == remote.absoluteString, Self.strongETag(info.etag),
           size > 0, info.total.map({ size <= $0 }) ?? true {
            received = size
        } else {
            resumeInfo = nil
            try h.truncate(atOffset: 0)
            try h.seek(toOffset: 0) // truncate does not reset the open file's write offset
            received = 0
            try? fm.removeItem(at: metadataURL)
        }
        offset = received
        expected = 0
        acceptedResponse = false
        responseError = nil
        lastReport = .distantPast
        var request = URLRequest(url: remote)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if offset > 0, let info = resumeInfo {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            request.setValue(info.etag, forHTTPHeaderField: "If-Range")
        }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                continuation = c
                task.resume()
            }
        }, onCancel: { task.cancel() })
    }

    private static func strongETag(_ value: String) -> Bool {
        value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"")
            && !value.contains("\r") && !value.contains("\n")
    }

    private static func contentRange(_ value: String) -> (start: Int64, end: Int64, total: Int64)? {
        let fields = value.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 2, fields[0] == "bytes" else { return nil }
        let lengths = fields[1].split(separator: "/", omittingEmptySubsequences: false)
        guard lengths.count == 2, let total = Int64(lengths[1]), total > 0 else { return nil }
        let range = lengths[0].split(separator: "-", omittingEmptySubsequences: false)
        guard range.count == 2, let start = Int64(range[0]), let end = Int64(range[1]),
              start >= 0, end >= start, end < total else { return nil }
        return (start, end, total)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let http = response as? HTTPURLResponse else { throw IntegrityError("download requires an HTTP response") }
            let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
            guard encoding == nil || encoding == "identity" else { throw IntegrityError("encoded image responses cannot be resumed safely") }
            switch http.statusCode {
            case 200:
                // A new entity or a server ignoring Range: replace every old byte from offset zero.
                try handle?.truncate(atOffset: 0)
                try handle?.seek(toOffset: 0)
                received = 0
                expected = max(http.expectedContentLength, 0)
                if let tag = http.value(forHTTPHeaderField: "ETag"), Self.strongETag(tag) {
                    let info = ResumeInfo(remote: remote.absoluteString, etag: tag, total: expected > 0 ? expected : nil)
                    try JSONEncoder().encode(info).write(to: metadataURL, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
                } else { try? FileManager.default.removeItem(at: metadataURL) }
            case 206:
                guard offset > 0, let info = resumeInfo,
                      http.value(forHTTPHeaderField: "ETag") == info.etag,
                      let text = http.value(forHTTPHeaderField: "Content-Range"),
                      let range = Self.contentRange(text), range.start == offset,
                      range.end == range.total - 1,
                      info.total.map({ $0 == range.total }) ?? true,
                      http.expectedContentLength < 0 || http.expectedContentLength == range.total - offset else {
                    throw IntegrityError("download resume has a mismatched entity or Content-Range; retry to restart the image")
                }
                expected = range.total
            case 500...599:
                throw VitrineError.io("download failed: HTTP \(http.statusCode)")
            default:
                throw IntegrityError("download failed: HTTP \(http.statusCode)")
            }
            acceptedResponse = true
            completionHandler(.allow)
        } catch {
            responseError = error
            if error is IntegrityError { try? FileManager.default.removeItem(at: metadataURL) }
            // Wait for didCompleteWithError before resuming: late cancellation callbacks must
            // never complete the continuation belonging to a subsequent retry.
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard acceptedResponse, responseError == nil else { return }
        do {
            if expected > 0, Int64(data.count) > expected - received {
                throw IntegrityError("download body exceeds its declared image length")
            }
            try handle?.write(contentsOf: data)
            received += Int64(data.count)
            if Date().timeIntervalSince(lastReport) > 0.5 {
                lastReport = Date()
                progress(expected > 0 ? Double(received) / Double(expected) : 0, received, expected)
            }
        } catch {
            responseError = error
            if error is IntegrityError { try? FileManager.default.removeItem(at: metadataURL) }
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { continuation = nil }
        if let error = responseError ?? error { continuation?.resume(throwing: error); return }
        guard acceptedResponse, received > 0, expected == 0 || received == expected else {
            continuation?.resume(throwing: IntegrityError("download did not contain a complete image"))
            return
        }
        progress(1, received, expected)
        continuation?.resume()
    }
}
