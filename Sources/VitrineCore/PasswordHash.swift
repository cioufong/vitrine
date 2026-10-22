import Foundation
import CryptoKit
import Security

/// Password hashes for guest seeds, so installer media never carries the password itself.
public enum PasswordHash {
    /// SHA-512 crypt ("$6$…", Drepper's spec), the format Linux shadow files and cloud-init's
    /// `passwd:` expect. `salt` is for tests; by default 16 random characters are used.
    public static func sha512Crypt(_ password: String, salt: String? = nil) -> String {
        let salt = String((salt ?? randomSalt()).prefix(16))
        let p = Array(password.utf8), s = Array(salt.utf8)
        let rounds = 5000

        func sha(_ parts: [UInt8]...) -> [UInt8] {
            var h = SHA512()
            for part in parts { h.update(data: part) }
            return Array(h.finalize())
        }
        func repeated(_ digest: [UInt8], count: Int) -> [UInt8] {
            (0..<count).map { digest[$0 % 64] }
        }

        let b = sha(p, s, p)
        var aCtx = SHA512()
        aCtx.update(data: p); aCtx.update(data: s)
        aCtx.update(data: repeated(b, count: p.count))
        var n = p.count
        while n > 0 { aCtx.update(data: n & 1 != 0 ? b : p); n >>= 1 }
        var a = Array(aCtx.finalize())

        var dp = SHA512()
        for _ in 0..<p.count { dp.update(data: p) }
        let pSeq = repeated(Array(dp.finalize()), count: p.count)
        var ds = SHA512()
        for _ in 0..<(16 + Int(a[0])) { ds.update(data: s) }
        let sSeq = repeated(Array(ds.finalize()), count: s.count)

        for i in 0..<rounds {
            var c = SHA512()
            c.update(data: i & 1 != 0 ? pSeq : a)
            if i % 3 != 0 { c.update(data: sSeq) }
            if i % 7 != 0 { c.update(data: pSeq) }
            c.update(data: i & 1 != 0 ? a : pSeq)
            a = Array(c.finalize())
        }

        let order: [(Int, Int, Int)] = [
            (0, 21, 42), (22, 43, 1), (44, 2, 23), (3, 24, 45), (25, 46, 4), (47, 5, 26), (6, 27, 48),
            (28, 49, 7), (50, 8, 29), (9, 30, 51), (31, 52, 10), (53, 11, 32), (12, 33, 54), (34, 55, 13),
            (56, 14, 35), (15, 36, 57), (37, 58, 16), (59, 17, 38), (18, 39, 60), (40, 61, 19), (62, 20, 41),
        ]
        var out = ""
        for (x, y, z) in order { out += b64(UInt32(a[x]) << 16 | UInt32(a[y]) << 8 | UInt32(a[z]), 4) }
        out += b64(UInt32(a[63]), 2)
        return "$6$\(salt)$\(out)"
    }

    private static let alphabet = Array("./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    private static func b64(_ v: UInt32, _ n: Int) -> String {
        var v = v, s = ""
        for _ in 0..<n { s.append(alphabet[Int(v & 0x3f)]); v >>= 6 }
        return s
    }

    private static func randomSalt() -> String {
        // SystemRandomNumberGenerator is the kernel CSPRNG on Darwin (unlike SecRandomCopyBytes it can't fail).
        var rng = SystemRandomNumberGenerator()
        return String((0..<16).map { _ in alphabet[Int.random(in: 0..<64, using: &rng)] })
    }

    /// The obfuscated form Windows unattend files accept with `<PlainText>false</PlainText>`:
    /// base64 of UTF-16LE(password + element name). Windows has no hashed form for unattend
    /// passwords (auto-logon needs the real one), so this only keeps it from being readable at a glance.
    public static func unattendObfuscated(_ password: String, element: String = "Password") -> String {
        var data = Data()
        for unit in (password + element).utf16 { data.append(UInt8(unit & 0xff)); data.append(UInt8(unit >> 8)) }
        return data.base64EncodedString()
    }
}
