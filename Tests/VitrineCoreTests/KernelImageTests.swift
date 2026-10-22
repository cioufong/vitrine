import XCTest
@testable import VitrineCore

final class KernelImageTests: XCTestCase {
    /// A fake arm64 Image: 64-byte header with the "ARMd" magic at 0x38, then filler.
    func fakeImage(size: Int = 200_000) -> Data {
        var d = Data(count: size)
        d.replaceSubrange(0x38..<0x3C, with: [0x41, 0x52, 0x4D, 0x64])
        for i in 0x40..<size { d[i] = UInt8(truncatingIfNeeded: i &* 31 &+ (i >> 7)) }
        return d
    }

    func gzip(_ data: Data) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("k-\(UUID().uuidString)")
        try data.write(to: tmp)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        p.arguments = ["-n", "-k", "-f", tmp.path]
        try p.run(); p.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: tmp); try? FileManager.default.removeItem(atPath: tmp.path + ".gz") }
        return try Data(contentsOf: URL(fileURLWithPath: tmp.path + ".gz"))
    }

    func testDetectsRawImage() {
        XCTAssertEqual(KernelImage.detect(fakeImage()), .arm64Image)
        XCTAssertEqual(KernelImage.detect(Data(count: 100)), .unknown)
    }

    func testGunzipRejectsTruncatedHeader() {
        // FNAME flag set but the name is never NUL-terminated.
        var d = Data([0x1F, 0x8B, 8, 0x08, 0, 0, 0, 0, 0, 3])
        d.append(Data(repeating: 0x41, count: 32))
        XCTAssertThrowsError(try KernelImage.gunzip(d))
    }

    func testGunzipRoundTrip() throws {
        let image = fakeImage()
        let gz = try gzip(image)
        XCTAssertEqual(KernelImage.detect(gz), .gzip)
        XCTAssertEqual(try KernelImage.decompress(gz, format: .gzip), image)
    }

    func testEFIZbootPayload() throws {
        let image = fakeImage()
        let gz = try gzip(image)
        // Build a minimal zboot container: MZ, "zimg", payload offset/size, "gzip" name.
        var z = Data(count: 0x40)
        z[0] = 0x4D; z[1] = 0x5A
        z.replaceSubrange(4..<8, with: Data("zimg".utf8))
        let off = UInt32(0x40), size = UInt32(gz.count)
        withUnsafeBytes(of: off.littleEndian) { z.replaceSubrange(8..<12, with: $0) }
        withUnsafeBytes(of: size.littleEndian) { z.replaceSubrange(12..<16, with: $0) }
        z.replaceSubrange(0x18..<0x1C, with: Data("gzip".utf8))
        z.append(gz)
        XCTAssertEqual(KernelImage.detect(z), .efiZboot(compression: "gzip"))
        XCTAssertEqual(try KernelImage.decompress(z, format: .efiZboot(compression: "gzip")), image)
    }

    func testPrepareCachesDecompressedImage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kprep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("vmlinuz")
        try gzip(fakeImage()).write(to: src)
        let out = try KernelImage.prepare(src, cacheDir: dir.appendingPathComponent("cache"))
        XCTAssertEqual(KernelImage.detect(try Data(contentsOf: out)), .arm64Image)
        XCTAssertEqual(try KernelImage.prepare(src, cacheDir: dir.appendingPathComponent("cache")), out)
    }
}
