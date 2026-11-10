import Foundation
import CryptoKit

// Parsers for the text formats other VM tools store their machines in. All of them read
// untrusted files: sizes are capped, XML never loads a DTD or an entity, and nothing here touches
// any file but the one it is given.

/// A small read-only XML tree built with `XMLParser`. Element and attribute names lose their
/// namespace prefix ("rasd:ResourceType" → "ResourceType"): OVF, VirtualBox and Parallels files
/// mix prefixes freely, and nothing here depends on telling namespaces apart.
public final class ImportXML {
    public let name: String
    public let attributes: [String: String]
    public private(set) var children: [ImportXML] = []
    public private(set) var text = ""

    init(name: String, attributes: [String: String]) { self.name = name; self.attributes = attributes }

    public static let maximumSize = 16 << 20

    /// Parses `data`, refusing a document type declaration (so no external entity, DTD or entity
    /// expansion of any kind) and anything over `maximumSize`.
    public static func parse(_ data: Data, what: String) throws -> ImportXML {
        guard data.count <= maximumSize else { throw VitrineError.invalidConfig("\(what) is too large to be a VM configuration") }
        // No VM tool writes a DOCTYPE; refusing it outright also rules out internal entity bombs,
        // which shouldResolveExternalEntities doesn't.
        // VM tools write UTF-8 (or ASCII); a UTF-16/32 document would hide a DOCTYPE from the byte
        // search below, so those aren't read at all.
        if data.contains(0) || data.starts(with: [0xFE, 0xFF]) || data.starts(with: [0xFF, 0xFE]) {
            throw VitrineError.invalidConfig("\(what) isn't UTF-8 text")
        }
        if data.range(of: Data("<!DOCTYPE".utf8)) != nil || data.range(of: Data("<!ENTITY".utf8)) != nil
            || data.range(of: Data("<!doctype".utf8)) != nil {
            throw VitrineError.invalidConfig("\(what) declares a document type or entities, which VM configurations never do; refusing to read it")
        }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        let builder = Builder()
        parser.delegate = builder
        guard parser.parse(), !builder.sawDeclaration, let root = builder.root else {
            if builder.sawDeclaration {
                throw VitrineError.invalidConfig("\(what) declares a document type or entities, which VM configurations never do; refusing to read it")
            }
            let reason = parser.parserError.map { " (\($0.localizedDescription))" } ?? ""
            throw VitrineError.invalidConfig("\(what) isn't readable XML\(reason)")
        }
        return root
    }

    static func local(_ name: String) -> String {
        name.split(separator: ":", maxSplits: 1).last.map(String.init) ?? name
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: ImportXML?
        var stack: [ImportXML] = []
        var sawDeclaration = false
        private func refuse(_ parser: XMLParser) { sawDeclaration = true; parser.abortParsing() }
        // Second line of defence behind the byte search: any DTD content stops the parse.
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { refuse(parser) }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { refuse(parser) }
        func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?, systemID: String?, notationName: String?) { refuse(parser) }
        func parser(_ parser: XMLParser, foundElementDeclarationWithName elementName: String, model: String) { refuse(parser) }
        func parser(_ parser: XMLParser, foundAttributeDeclarationWithName attributeName: String, forElement elementName: String, type: String?, defaultValue: String?) { refuse(parser) }
        func parser(_ parser: XMLParser, foundNotationDeclarationWithName name: String, publicID: String?, systemID: String?) { refuse(parser) }
        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { refuse(parser); return nil }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            guard stack.count < 256 else { parser.abortParsing(); return }
            var attrs: [String: String] = [:]
            for (k, v) in attributeDict where !k.hasPrefix("xmlns") { attrs[ImportXML.local(k)] = v }
            let node = ImportXML(name: ImportXML.local(elementName), attributes: attrs)
            if let parent = stack.last { parent.children.append(node) } else { root = node }
            stack.append(node)
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            _ = stack.popLast()
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
        }
    }

    public subscript(_ attribute: String) -> String? { attributes[attribute] }

    /// First child named `name`.
    public func child(_ name: String) -> ImportXML? { children.first { $0.name == name } }
    public func all(_ name: String) -> [ImportXML] { children.filter { $0.name == name } }
    /// The child at a slash-separated path ("Hardware/Memory").
    public func at(_ path: String) -> ImportXML? {
        var node: ImportXML? = self
        for part in path.split(separator: "/") { node = node?.child(String(part)) }
        return node
    }
    public var value: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Every descendant (depth first) named `name`.
    public func descendants(_ name: String) -> [ImportXML] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
    }
}

/// VMware's `.vmx`/`.vmsd` key = "value" files. Keys are case-insensitive (stored lower-cased);
/// values are decoded per the file's `.encoding` and VMware's "|XX" escapes.
public struct VMXFile: Sendable {
    public private(set) var values: [String: String] = [:]

    public static let maximumSize = 4 << 20

    public init(data: Data) throws {
        guard data.count <= Self.maximumSize else { throw VitrineError.invalidConfig("the VMware configuration is too large") }
        // .encoding is ASCII; read it first to decode the rest.
        let ascii = String(decoding: data, as: UTF8.self)
        var encoding = String.Encoding.utf8
        if let enc = Self.parse(ascii)[".encoding"]?.lowercased() {
            switch enc {
            case "utf-8", "utf8": encoding = .utf8
            case "windows-1252", "cp1252": encoding = .windowsCP1252
            case "iso-8859-1", "latin1": encoding = .isoLatin1
            case "shift_jis": encoding = .shiftJIS
            default: encoding = .utf8
            }
        }
        let text = String(data: data, encoding: encoding) ?? ascii
        values = Self.parse(text)
    }

    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            out[key] = unescape(value)
        }
        return out
    }

    /// "|22" → "\"", "|7C" → "|" (VMware's escape for characters a value can't hold).
    static func unescape(_ s: String) -> String {
        guard s.contains("|") else { return s }
        var bytes: [UInt8] = []
        let u = Array(s.utf8)
        var i = 0
        while i < u.count {
            if u[i] == UInt8(ascii: "|"), i + 2 < u.count,
               let b = UInt8(String(decoding: u[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                bytes.append(b); i += 3
            } else {
                bytes.append(u[i]); i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    public subscript(_ key: String) -> String? { values[key.lowercased()] }
    public func bool(_ key: String) -> Bool? {
        guard let v = self[key]?.lowercased() else { return nil }
        return ["true", "yes", "1"].contains(v) ? true : ["false", "no", "0"].contains(v) ? false : nil
    }
    public var keys: Dictionary<String, String>.Keys { values.keys }
}

/// The text descriptor of a VMDK (a `.vmdk` that starts with "# Disk DescriptorFile", or the one
/// embedded in a sparse extent): its extents and parent link, read before `qemu-img` opens it.
public struct VMDKDescriptor: Sendable, Equatable {
    public struct Extent: Sendable, Equatable { public var access: String, type: String, file: String? }
    public var createType: String?
    public var parentCID: String?
    public var parentFileNameHint: String?
    public var extents: [Extent] = []

    public var hasParent: Bool {
        if let p = parentFileNameHint, !p.isEmpty { return true }
        if let c = parentCID?.lowercased(), c != "ffffffff" { return true }
        return false
    }

    /// nil when `data` isn't a text descriptor (a binary sparse/stream-optimized VMDK starts "KDMV").
    public init?(data: Data) {
        guard data.count <= 1 << 20, data.prefix(4) != Data("KDMV".utf8) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard text.contains("# Disk DescriptorFile") || text.lowercased().contains("createtype") else { return nil }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty { continue }
            let lower = line.lowercased()
            if let v = Self.value(line, key: "createType") { createType = v; continue }
            if let v = Self.value(line, key: "parentCID") { parentCID = v; continue }
            if let v = Self.value(line, key: "parentFileNameHint") { parentFileNameHint = v; continue }
            if lower.hasPrefix("rw ") || lower.hasPrefix("rdonly ") || lower.hasPrefix("noaccess ") {
                // RW <sectors> <TYPE> ["file" [offset]]
                let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                guard fields.count >= 3 else { continue }
                var file: String?
                if let q1 = line.firstIndex(of: "\""), let q2 = line[line.index(after: q1)...].firstIndex(of: "\"") {
                    file = String(line[line.index(after: q1)..<q2])
                }
                extents.append(Extent(access: String(fields[0]).uppercased(), type: String(fields[2]).uppercased(), file: file))
            }
        }
    }

    static func value(_ line: String, key: String) -> String? {
        guard let eq = line.firstIndex(of: "="),
              line[..<eq].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(key) == .orderedSame else { return nil }
        var v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
        return v
    }
}

/// An OVF package's `.mf`: "SHA256(file.vmdk)= <hex>" lines.
public enum OVFManifest {
    public static func parse(_ data: Data) throws -> [String: ImportPlan.Digest] {
        guard data.count <= 1 << 20 else { throw VitrineError.invalidConfig("the manifest is too large") }
        var out: [String: ImportPlan.Digest] = [:]
        for raw in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let open = line.firstIndex(of: "("), let close = line.lastIndex(of: ")"), open < close,
                  let eq = line[close...].firstIndex(of: "=") else {
                throw VitrineError.invalidConfig("unreadable manifest line \(line.prefix(80).debugDescription)")
            }
            let alg = line[..<open].trimmingCharacters(in: .whitespaces).uppercased().replacingOccurrences(of: "-", with: "")
            let file = String(line[line.index(after: open)..<close])
            let hex = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces).lowercased()
            let algorithm: ImportPlan.Digest.Algorithm, length: Int
            switch alg {
            case "SHA1": (algorithm, length) = (.sha1, 40)
            case "SHA256": (algorithm, length) = (.sha256, 64)
            case "SHA512": (algorithm, length) = (.sha512, 128)
            default: throw VitrineError.unsupported("manifest digest \(alg) isn't supported (SHA1, SHA256 and SHA512 are)")
            }
            guard hex.count == length, hex.allSatisfy(\.isHexDigit) else {
                throw VitrineError.invalidConfig("manifest digest for \(file) is malformed")
            }
            out[file] = .init(algorithm: algorithm, hex: hex)
        }
        return out
    }
}

/// Incremental digest for the manifest algorithms.
public struct ImportHasher {
    private var sha1 = Insecure.SHA1()
    private var sha256 = SHA256()
    private var sha512 = SHA512()
    public let algorithm: ImportPlan.Digest.Algorithm
    public init(_ algorithm: ImportPlan.Digest.Algorithm) { self.algorithm = algorithm }
    public mutating func update(_ data: Data) {
        switch algorithm {
        case .sha1: sha1.update(data: data)
        case .sha256: sha256.update(data: data)
        case .sha512: sha512.update(data: data)
        }
    }
    public func finalize() -> String {
        let bytes: [UInt8]
        switch algorithm {
        case .sha1: bytes = Array(sha1.finalize())
        case .sha256: bytes = Array(sha256.finalize())
        case .sha512: bytes = Array(sha512.finalize())
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Digest of `length` bytes of `file` from `offset`, checking `isCancelled` between chunks.
    public static func digest(of file: URL, offset: UInt64 = 0, length: UInt64? = nil,
                              algorithm: ImportPlan.Digest.Algorithm, isCancelled: () -> Bool = { false }) throws -> String {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        try h.seek(toOffset: offset)
        var hasher = ImportHasher(algorithm)
        var remaining = length ?? UInt64.max
        while remaining > 0 {
            if isCancelled() { throw VitrineError.cancelled }
            let chunk = try h.read(upToCount: Int(min(remaining, 8 << 20))) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(chunk)
            remaining -= UInt64(chunk.count)
        }
        if let length, remaining != 0 { throw VitrineError.io("\(file.lastPathComponent) ended early (\(length - remaining) of \(length) bytes)") }
        return hasher.finalize()
    }
}

/// The members of a tar archive (an OVA), read from its headers without extracting anything.
/// Only plain regular files with plain names are accepted: no directories, links, devices, pax or
/// GNU extension headers, no '/' or ".." in a name. OVF requires exactly that much of an OVA.
public enum TarListing {
    public struct Member: Sendable, Equatable { public var name: String; public var offset: UInt64; public var size: UInt64 }

    public static func list(_ archive: URL, maxMembers: Int = 256) throws -> [Member] {
        let h = try FileHandle(forReadingFrom: archive)
        defer { try? h.close() }
        let fileSize = try h.seekToEnd()
        var offset: UInt64 = 0
        var members: [Member] = []
        var names = Set<String>()
        func fail(_ m: String) -> Error { VitrineError.unsupported("\(archive.lastPathComponent): \(m)") }
        while offset + 512 <= fileSize {
            try h.seek(toOffset: offset)
            guard let header = try h.read(upToCount: 512), header.count == 512 else { throw fail("truncated archive") }
            if header.allSatisfy({ $0 == 0 }) { return members } // end-of-archive marker
            guard checksumOK(header) else { throw fail("corrupt archive header at byte \(offset)") }
            let name = cString(header.subdata(0, 100))
            let type = header[156]
            let magic = header.subdata(257, 5)
            if magic == Data("ustar".utf8), !cString(header.subdata(345, 155)).isEmpty {
                throw fail("member \(name.debugDescription) has a path prefix; OVA members must be plain file names")
            }
            guard type == UInt8(ascii: "0") || type == 0 else {
                let kind: String
                switch type {
                case UInt8(ascii: "1"): kind = "a hard link"
                case UInt8(ascii: "2"): kind = "a symbolic link"
                case UInt8(ascii: "3"), UInt8(ascii: "4"): kind = "a device"
                case UInt8(ascii: "5"): kind = "a directory"
                case UInt8(ascii: "6"): kind = "a FIFO"
                case UInt8(ascii: "x"), UInt8(ascii: "g"): kind = "a pax extended header"
                case UInt8(ascii: "L"), UInt8(ascii: "K"): kind = "a GNU long-name header"
                default: kind = "an entry of type \(String(UnicodeScalar(type)).debugDescription)"
                }
                throw fail("member \(name.debugDescription) is \(kind); an OVA holds only plain files")
            }
            guard isPlainName(name) else {
                throw fail("member name \(name.debugDescription) isn't a plain file name (no '/', '\\', '..' or control characters)")
            }
            guard names.insert(name).inserted else { throw fail("member \(name) appears twice") }
            guard let size = octal(header.subdata(124, 12)) ?? base256(header.subdata(124, 12)) else {
                throw fail("member \(name) has an unreadable size")
            }
            let data = offset + 512
            guard data + size <= fileSize else { throw fail("member \(name) is truncated") }
            members.append(Member(name: name, offset: data, size: size))
            guard members.count <= maxMembers else { throw fail("too many members") }
            offset = data + (size + 511) / 512 * 512
        }
        // Some writers omit the end-of-archive blocks.
        guard offset == fileSize || members.isEmpty == false else { throw fail("not a tar archive") }
        return members
    }

    public static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F } && name.utf8.count < 100
    }

    static func cString(_ d: Data) -> String {
        String(decoding: d.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// Octal (NUL/space padded); base-256 sizes (high bit set) aren't accepted.
    static func octal(_ d: Data) -> UInt64? {
        guard let first = d.first, first & 0x80 == 0 else { return nil }
        let s = cString(d).trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.allSatisfy({ ("0"..."7").contains($0) }) else { return nil }
        return UInt64(s, radix: 8)
    }

    /// GNU/star base-256 numbers (high bit of the first byte set), which tar writers use for sizes
    /// of 8 GiB and more. Only for the size field: it is a number, with no path in it.
    static func base256(_ d: Data) -> UInt64? {
        guard let first = d.first, first & 0x80 != 0, first & 0x40 == 0 else { return nil } // positive only
        var v = UInt64(first & 0x3F)
        for b in d.dropFirst() {
            guard v >> 56 == 0 else { return nil }
            v = v << 8 | UInt64(b)
        }
        return v
    }

    static func checksumOK(_ header: Data) -> Bool {
        guard let stored = octal(header.subdata(148, 8)) else { return false }
        var sum: UInt64 = 0
        for (i, b) in header.enumerated() { sum += (148..<156).contains(i) ? 32 : UInt64(b) }
        return sum == stored
    }
}
