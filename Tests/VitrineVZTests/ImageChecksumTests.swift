import XCTest
@testable import VitrineVZ

final class ImageChecksumTests: XCTestCase {
    let a = String(repeating: "a", count: 128), b = String(repeating: "B", count: 128)

    func testFindsTheEntryForTheImage() {
        let listing = "\(a)  debian-13-generic-amd64.tar.xz\n\(b)  debian-13-generic-arm64.tar.xz\n"
        XCTAssertEqual(CloudImageInstaller.sha512Entry(in: listing, for: "debian-13-generic-arm64.tar.xz"), b.lowercased())
        XCTAssertEqual(CloudImageInstaller.sha512Entry(in: "\(a) *disk.tar.xz", for: "disk.tar.xz"), a)
    }

    func testRejectsMissingOrMalformedEntries() {
        XCTAssertNil(CloudImageInstaller.sha512Entry(in: "\(a)  other.tar.xz", for: "disk.tar.xz"))
        XCTAssertNil(CloudImageInstaller.sha512Entry(in: "abc123  disk.tar.xz", for: "disk.tar.xz"))
        XCTAssertNil(CloudImageInstaller.sha512Entry(in: String(repeating: "z", count: 128) + "  disk.tar.xz", for: "disk.tar.xz"))
        XCTAssertNil(CloudImageInstaller.sha512Entry(in: "\(a)  disk.tar.xz.part", for: "disk.tar.xz"))
    }

    func testHashesFiles() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: f)
        defer { try? FileManager.default.removeItem(at: f) }
        XCTAssertEqual(try CloudImageInstaller.sha512(of: f),
                       "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
    }

    func testDebianListsItsChecksumFile() {
        XCTAssertEqual(CloudImageInstaller.debian13.checksums.scheme, "https")
        XCTAssertEqual(CloudImageInstaller.debian13.checksums.deletingLastPathComponent(),
                       CloudImageInstaller.debian13.url.deletingLastPathComponent())
    }
}
