import Foundation
import Compression

/// Prepares Linux kernels for `VZLinuxBootLoader`, which only accepts an uncompressed arm64 `Image`.
/// Distributions often ship gzip-compressed kernels or EFI "zboot" PE images wrapping a gzip payload.
public enum KernelImage {
    public enum Format: Equatable, Sendable {
        case arm64Image      // raw Image ("ARM\x64" magic at 0x38)
        case gzip
        case efiZboot(compression: String)
        case unknown
    }

    public static func detect(_ data: Data) -> Format {
        if data.count >= 0x3C, data[data.startIndex + 0x38 ..< data.startIndex + 0x3C] == Data([0x41, 0x52, 0x4D, 0x64]) {
            return .arm64Image
        }
        if data.count >= 2, data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B { return .gzip }
        // EFI zboot: "MZ" ... "zimg" at offset 4, payload offset/size at 8/12, compression name at 0x18.
        if data.count >= 0x20, data[data.startIndex] == 0x4D, data[data.startIndex + 1] == 0x5A,
           data[data.startIndex + 4 ..< data.startIndex + 8] == Data("zimg".utf8) {
            let nameBytes = data[data.startIndex + 0x18 ..< data.startIndex + 0x20].prefix { $0 != 0 }
            return .efiZboot(compression: String(decoding: nameBytes, as: UTF8.self))
        }
        return .unknown
    }

    /// Returns a path to an uncompressed Image, decompressing into `cacheDir` when needed.
    public static func prepare(_ url: URL, cacheDir: URL) throws -> URL {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let format = detect(data)
        if format == .arm64Image { return url }
        let out = cacheDir.appendingPathComponent(url.lastPathComponent + ".Image")
        if let a = try? out.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           let b = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, a >= b,
           FileManager.default.fileExists(atPath: out.path) {
            return out
        }
        let image = try decompress(data, format: format)
        guard detect(image) == .arm64Image else {
            throw VitrineError.unsupported("\(url.lastPathComponent) did not decompress to an arm64 Image")
        }
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try image.write(to: out, options: .atomic)
        return out
    }

    public static func decompress(_ data: Data, format: Format) throws -> Data {
        switch format {
        case .arm64Image: return data
        case .gzip: return try gunzip(data)
        case .efiZboot(let compression):
            guard compression == "gzip" else {
                throw VitrineError.unsupported("zboot kernel compressed with \(compression); only gzip is supported — use EFI boot instead")
            }
            func u32(_ off: Int) -> Int {
                let b = data.startIndex + off
                return Int(data[b]) | Int(data[b + 1]) << 8 | Int(data[b + 2]) << 16 | Int(data[b + 3]) << 24
            }
            let offset = u32(8), size = u32(12)
            guard offset > 0, size > 0, offset + size <= data.count else {
                throw VitrineError.unsupported("corrupt zboot header")
            }
            return try gunzip(data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + size))
        case .unknown:
            throw VitrineError.unsupported("unrecognised kernel format (expected arm64 Image, gzip or EFI zboot)")
        }
    }

    /// Decodes a gzip member (RFC 1952) with Compression's raw-DEFLATE decoder.
    public static func gunzip(_ data: Data) throws -> Data {
        guard data.count > 18, data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B,
              data[data.startIndex + 2] == 8 else { throw VitrineError.unsupported("not a gzip stream") }
        let flags = data[data.startIndex + 3]
        let truncated = VitrineError.unsupported("truncated gzip header")
        var pos = data.startIndex + 10
        func skipString() throws {
            guard let nul = data[pos...].firstIndex(of: 0) else { throw truncated }
            pos = nul + 1
        }
        if flags & 0x04 != 0 { // FEXTRA
            guard pos + 2 <= data.endIndex else { throw truncated }
            let xlen = Int(data[pos]) | Int(data[pos + 1]) << 8
            pos += 2 + xlen
        }
        if flags & 0x08 != 0, pos < data.endIndex { try skipString() } // FNAME
        if flags & 0x10 != 0, pos < data.endIndex { try skipString() } // FCOMMENT
        if flags & 0x02 != 0 { pos += 2 }                              // FHCRC
        guard pos < data.endIndex else { throw truncated }
        let deflate = data.subdata(in: pos ..< data.endIndex)
        return try inflate(deflate)
    }

    static func inflate(_ input: Data) throws -> Data {
        var output = Data()
        let chunk = 1 << 20
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }
        var stream = compression_stream(dst_ptr: dst, dst_size: chunk, src_ptr: dst, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw VitrineError.io("inflate init failed")
        }
        defer { compression_stream_destroy(&stream) }
        try input.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            stream.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!
            stream.src_size = src.count
            while true {
                stream.dst_ptr = dst
                stream.dst_size = chunk
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(dst, count: chunk - stream.dst_size)
                if status == COMPRESSION_STATUS_END { break }
                guard status == COMPRESSION_STATUS_OK else { throw VitrineError.io("inflate failed") }
                if stream.src_size == 0 && stream.dst_size == chunk { break }
            }
        }
        return output
    }
}
