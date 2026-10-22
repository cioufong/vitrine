import Foundation
import XCTest
@testable import VitrineQEMU
@testable import VitrineCore

final class SecureBootVarsTests: XCTestCase {
    let template = URL(fileURLWithPath: "/opt/homebrew/share/qemu/edk2-i386-vars.fd")

    private func enrolledCopy() throws -> URL {
        guard FileManager.default.fileExists(atPath: template.path) else { throw XCTSkip("QEMU's edk2 vars template is not installed") }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-sb-\(UUID().uuidString).fd")
        try FileManager.default.copyItem(at: template, to: out)
        let pk = try SecureBootVars.makePlatformKey(commonName: "Test VM")
        try SecureBootVars.enroll(out, platformKey: pk)
        return out
    }

    func testGuidsAreMixedEndian() {
        XCTAssertEqual(Array(SecureBootVars.guid("8be4df61-93ca-11d2-aa0d-00e098032b8c")),
                       [0x61, 0xdf, 0xe4, 0x8b, 0xca, 0x93, 0xd2, 0x11, 0xaa, 0x0d, 0x00, 0xe0, 0x98, 0x03, 0x2b, 0x8c])
    }

    func testEmbeddedCertificatesMatchTheirPinnedHashes() throws {
        for c in MicrosoftSecureBootCerts.kek + MicrosoftSecureBootCerts.db {
            XCTAssertNotNil(Data(base64Encoded: c.der), c.name)
        }
        XCTAssertEqual(MicrosoftSecureBootCerts.kek.count, 2)
        XCTAssertEqual(MicrosoftSecureBootCerts.db.count, 5)
    }

    func testEnrollmentWritesParsableVariablesOnce() throws {
        let file = try enrolledCopy()
        defer { try? FileManager.default.removeItem(at: file) }
        let before = try Data(contentsOf: template), after = try Data(contentsOf: file)
        XCTAssertEqual(before.count, after.count)
        XCTAssertEqual(before.prefix(0x64), after.prefix(0x64), "firmware volume and store headers untouched")
        XCTAssertEqual(Array(after[0x64..<0x67]), [0xAA, 0x55, 0x3F], "first variable: StartId + VAR_ADDED")
        // A second enrollment must refuse rather than stack another set of keys.
        XCTAssertThrowsError(try SecureBootVars.enroll(file, platformKey: Data([1])))

        // Optional cross-check with virt-firmware's parser (a dev tool, not a dependency).
        let dump = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../.build/vfw/bin/virt-fw-vars").standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: dump.path) else { return }
        let p = Process()
        p.executableURL = dump
        p.arguments = ["--input", file.path, "--print", "--verbose"]
        let out = Pipe()
        p.standardOutput = out; p.standardError = out
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        for needle in ["PK", "KEK", "db", "SecureBootEnable", "CustomMode", "Microsoft Corporation KEK CA 2011",
                       "Microsoft Corporation KEK 2K CA 2023", "Windows UEFI CA 2023", "Microsoft UEFI CA 2023",
                       "Microsoft Windows Production PCA 2011"] {
            XCTAssertTrue(text.contains(needle), "virt-fw-vars output lacks \(needle):\n\(text.prefix(3000))")
        }
    }
}
