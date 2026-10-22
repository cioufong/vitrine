import XCTest
import Foundation
import Darwin
@testable import VitrineVZ

/// Real loopback HTTP responses exercise URLSession's framing and interrupted-transfer behavior.
final class DownloadIntegrityTests: XCTestCase {
    private func partial() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("download-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("image.part")
    }

    func testCompleteDownloadPreservesBytes() async throws {
        let server = try HTTPFixture { _, _ in .init(body: "ABCDEFGH", etag: "\"v1\"") }
        defer { server.close() }
        let file = try partial()
        try await ResumableDownloader(remote: server.url, partial: file, progress: { _, _, _ in }).run()
        XCTAssertEqual(try Data(contentsOf: file), Data("ABCDEFGH".utf8))
    }

    func testLegacyPartialIsRestartedWithoutSparsePrefix() async throws {
        let server = try HTTPFixture { _, _ in .init(body: "NEW", etag: "\"v2\"") }
        defer { server.close() }
        let file = try partial()
        try Data("OLD-PARTIAL".utf8).write(to: file)
        try await ResumableDownloader(remote: server.url, partial: file, progress: { _, _, _ in }).run()
        XCTAssertEqual(try Data(contentsOf: file), Data("NEW".utf8))
    }

    func testNoContentCannotBecomeCompletedImage() async throws {
        let server = try HTTPFixture { _, _ in .init(status: 204, body: "") }
        defer { server.close() }
        let file = try partial()
        do {
            try await ResumableDownloader(remote: server.url, partial: file, progress: { _, _, _ in }).run()
            XCTFail("HTTP 204 must not be accepted as a complete image")
        } catch { }
    }

    func testUnsolicitedPartialResponseIsRejected() async throws {
        let server = try HTTPFixture { _, _ in
            .init(status: 206, body: "EFGH", etag: "\"v1\"", headers: ["Content-Range": "bytes 4-7/8"])
        }
        defer { server.close() }
        let file = try partial()
        do {
            try await ResumableDownloader(remote: server.url, partial: file, progress: { _, _, _ in }).run()
            XCTFail("a response starting at byte 4 cannot complete a new file")
        } catch { }
    }

    func testInterruptedTransferResumesWithMatchingStrongETagAndRange() async throws {
        let prefix = String(repeating: "A", count: 131_072)
        let server = try HTTPFixture { index, headers in
            if index == 0 { return .init(body: prefix, etag: "\"v1\"", declaredLength: prefix.utf8.count + 4) }
            XCTAssertEqual(headers["range"], "bytes=131072-")
            XCTAssertEqual(headers["if-range"], "\"v1\"")
            return .init(status: 206, body: "EFGH", etag: "\"v1\"", headers: ["Content-Range": "bytes 131072-131075/131076"])
        }
        defer { server.close() }
        let file = try partial()
        try await ResumableDownloader(remote: server.url, partial: file, progress: { _, _, _ in }).run()
        XCTAssertEqual(try Data(contentsOf: file), Data((prefix + "EFGH").utf8))
    }

    func testChangedEntityReturningFullResponseRestartsAtOffsetZero() async throws {
        let prefix = String(repeating: "A", count: 131_072)
        let server = try HTTPFixture { index, _ in
            if index == 0 { return .init(body: prefix, etag: "\"v1\"", declaredLength: prefix.utf8.count + 4) }
            return .init(body: "NEW-IMAGE", etag: "\"v2\"")
        }
        defer { server.close() }
        let file = try partial()
        try await ResumableDownloader(remote: server.url, partial: file, progress: { _, _, _ in }).run()
        XCTAssertEqual(try Data(contentsOf: file), Data("NEW-IMAGE".utf8))
    }

    func testMismatchedRangeCannotConcatenateImageVersions() async throws {
        let prefix = String(repeating: "A", count: 131_072)
        let server = try HTTPFixture { index, _ in
            if index == 0 { return .init(body: prefix, etag: "\"v1\"", declaredLength: prefix.utf8.count + 4) }
            return .init(status: 206, body: "EFGH", etag: "\"v1\"", headers: ["Content-Range": "bytes 0-3/131076"])
        }
        defer { server.close() }
        let file = try partial()
        do {
            try await ResumableDownloader(remote: server.url, partial: file, progress: { _, _, _ in }).run()
            XCTFail("wrong resumed offset must fail")
        } catch { }
        XCTAssertNotEqual(try Data(contentsOf: file), Data((prefix + "EFGH").utf8))
    }

    func testEmptyLegacyCacheIsDownloadedAgain() async throws {
        let server = try HTTPFixture { _, _ in .init(body: "COMPLETE", etag: "\"v1\"") }
        defer { server.close() }
        let cache = try partial().deletingLastPathComponent()
        let old = ProcessInfo.processInfo.environment["VITRINE_CACHE"]
        setenv("VITRINE_CACHE", cache.path, 1)
        defer { if let old { setenv("VITRINE_CACHE", old, 1) } else { unsetenv("VITRINE_CACHE") } }
        let dir = cache.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("image"))
        let image = try await RestoreImages.downloadToCache(server.url, subdirectory: "images", progress: { _, _, _ in })
        XCTAssertEqual(try Data(contentsOf: image), Data("COMPLETE".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.path + ".part.http.json"))
    }

    func testCompletedCacheSeparatesRemoteURLsWithSameBasename() async throws {
        let first = try HTTPFixture { _, _ in .init(body: "FIRST") }
        let second = try HTTPFixture { _, _ in .init(body: "SECOND") }
        defer { first.close(); second.close() }
        let cache = try partial().deletingLastPathComponent()
        let old = ProcessInfo.processInfo.environment["VITRINE_CACHE"]
        setenv("VITRINE_CACHE", cache.path, 1)
        defer { if let old { setenv("VITRINE_CACHE", old, 1) } else { unsetenv("VITRINE_CACHE") } }
        let a = try await RestoreImages.downloadToCache(first.url, subdirectory: "images", progress: { _, _, _ in })
        let b = try await RestoreImages.downloadToCache(second.url, subdirectory: "images", progress: { _, _, _ in })
        XCTAssertEqual(try Data(contentsOf: a), Data("FIRST".utf8))
        XCTAssertEqual(try Data(contentsOf: b), Data("SECOND".utf8))
        XCTAssertNotEqual(a, b)
    }

    func testConcurrentDownloadRefusesSharedPartialBeforeOpeningIt() async throws {
        try await checkConcurrentOwnership(filename: "image")
    }

    func testImageNamedDownloadLockCannotUnlinkOwnershipLock() async throws {
        try await checkConcurrentOwnership(filename: "download.lock")
    }

    private func checkConcurrentOwnership(filename: String) async throws {
        let arrived = expectation(description: "first download owns destination")
        let release = DispatchSemaphore(value: 0)
        let server = try HTTPFixture(filename: filename) { index, _ in
            if index == 0 {
                arrived.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
            return .init(body: "COMPLETE")
        }
        defer { release.signal(); server.close() }
        let cache = try partial().deletingLastPathComponent()
        let old = ProcessInfo.processInfo.environment["VITRINE_CACHE"]
        setenv("VITRINE_CACHE", cache.path, 1)
        defer { if let old { setenv("VITRINE_CACHE", old, 1) } else { unsetenv("VITRINE_CACHE") } }
        let first = Task { try await RestoreImages.downloadToCache(server.url, subdirectory: "images", progress: { _, _, _ in }) }
        await fulfillment(of: [arrived], timeout: 3)
        do {
            _ = try await RestoreImages.downloadToCache(server.url, subdirectory: "images", progress: { _, _, _ in })
            XCTFail("second download must not touch an owned partial")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("download is already in progress"), "\(error)")
        }
        release.signal()
        let image = try await first.value
        XCTAssertEqual(try Data(contentsOf: image), Data("COMPLETE".utf8))
    }
}

private final class HTTPFixture {
    struct Response {
        var status = 200
        var body: String
        var etag: String? = nil
        var declaredLength: Int? = nil
        var headers: [String: String] = [:]
    }
    let url: URL
    private let fd: Int32
    private let lock = NSLock()
    private var stopped = false

    init(filename: String = "image", response: @escaping (Int, [String: String]) -> Response) throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(.EIO) }
        fd = socketFD
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, size) == 0 && getsockname(socketFD, $0, &size) == 0
            }
        }
        guard bound, listen(fd, 8) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: addr.sin_port))")!.appendingPathComponent(filename)
        DispatchQueue.global().async { [weak self] in self?.serve(response) }
    }

    func close() {
        lock.lock(); stopped = true; lock.unlock()
        shutdown(fd, SHUT_RDWR)
    }
    deinit { Darwin.close(fd) }

    private func serve(_ response: (Int, [String: String]) -> Response) {
        var index = 0
        while true {
            lock.lock(); let done = stopped; lock.unlock()
            if done { return }
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&event, 1, 100) <= 0 { continue }
            let client = accept(fd, nil, nil)
            if client < 0 { continue }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout.size(ofValue: on)))
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while data.count < 16_384 && !data.containsHTTPHeaderEnd {
                let n = recv(client, &buffer, buffer.count, 0)
                if n <= 0 { break }
                data.append(contentsOf: buffer.prefix(n))
            }
            let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
            var headers = [String: String]()
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let result = response(index, headers)
            index += 1
            var wire = "HTTP/1.1 \(result.status) Test\r\nContent-Length: \(result.declaredLength ?? result.body.utf8.count)\r\nConnection: close\r\n"
            if let etag = result.etag { wire += "ETag: \(etag)\r\n" }
            for (key, value) in result.headers { wire += "\(key): \(value)\r\n" }
            wire += "\r\n" + result.body
            Data(wire.utf8).withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let n = send(client, bytes.baseAddress! + offset, bytes.count - offset, 0)
                    if n <= 0 { break }
                    offset += n
                }
            }
            if result.declaredLength != nil { Thread.sleep(forTimeInterval: 0.2) }
            Darwin.close(client)
        }
    }
}

private extension Data {
    var containsHTTPHeaderEnd: Bool { range(of: Data("\r\n\r\n".utf8)) != nil }
}
