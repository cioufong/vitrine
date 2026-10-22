import XCTest
@testable import VitrineCore

final class PasswordHashTests: XCTestCase {
    /// Test vectors from Drepper's "Unix crypt using SHA-256 and SHA-512" (default 5000 rounds).
    func testSHA512CryptVectors() {
        XCTAssertEqual(PasswordHash.sha512Crypt("Hello world!", salt: "saltstring"),
                       "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1")
        // Salts are cut to 16 characters.
        XCTAssertEqual(PasswordHash.sha512Crypt("a very much longer text to encrypt.  This one even stretches over morethan one line.",
                                                salt: "toolongsaltstringforthis"),
                       PasswordHash.sha512Crypt("a very much longer text to encrypt.  This one even stretches over morethan one line.",
                                                salt: "toolongsaltstrin"))
    }

    func testRandomSaltDiffers() {
        let a = PasswordHash.sha512Crypt("pw"), b = PasswordHash.sha512Crypt("pw")
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasPrefix("$6$"))
        XCTAssertEqual(a.split(separator: "$").map(\.count), [1, 16, 86])
    }

    func testUnattendObfuscation() {
        let s = PasswordHash.unattendObfuscated("P@ssw0rd")
        let d = Data(base64Encoded: s)!
        let units = stride(from: 0, to: d.count, by: 2).map { UInt16(d[$0]) | UInt16(d[$0 + 1]) << 8 }
        XCTAssertEqual(String(utf16CodeUnits: units, count: units.count), "P@ssw0rdPassword")
        XCTAssertFalse(s.contains("P@ssw0rd"))
    }
}
