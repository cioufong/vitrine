import Foundation
import XCTest
@testable import VitrineCore

/// A config written by an older build lacks the keys added since. Every setting that has a default
/// must load without its key (taking that default); only what has no sensible default may be required.
final class ConfigMissingKeyTests: XCTestCase {
    /// Keys whose absence makes a config unusable, by their path in config.json.
    static let required: Set<String> = [
        "name", "guestOS", "cpuCount", "memoryMiB",
        "disks[].path", "shares[].hostPath", "shares[].name",
        "network.portForwards[].hostPort", "network.portForwards[].guestPort",
        "account.fullName", "account.username",
    ]

    func testEveryDefaultedKeyMayBeMissing() throws {
        var config = VMConfig(name: "Old", guestOS: .linux, cpuCount: 2, memoryMiB: 4096)
        config.disks = [.init(path: "disk.img")]
        config.shares = [.init(hostPath: "/tmp", name: "tmp")]
        config.network.portForwards = [.init(hostPort: 2222, guestPort: 22)]
        config.account = .init(fullName: "A", username: "a")
        let full = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as! [String: Any]

        var checked = 0
        for path in Self.keyPaths(in: full, prefix: "") {
            let trimmed = Self.removing(path.split(separator: ".").map(String.init), from: full)
            let data = try JSONSerialization.data(withJSONObject: trimmed)
            let decoded = Result { try JSONDecoder().decode(VMConfig.self, from: data) }
            if Self.required.contains(path) {
                XCTAssertThrowsError(try decoded.get(), "\(path) is required")
            } else {
                XCTAssertNoThrow(try decoded.get(), "config without \(path) must still load")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 30)
    }

    func testMissingKeysTakeTheirDefaults() throws {
        let json = #"""
        {"name":"Old","guestOS":"linux","cpuCount":2,"memoryMiB":4096,
         "disks":[{"path":"disk.img"}],"shares":[{"hostPath":"/tmp","name":"tmp"}],
         "network":{"portForwards":[{"hostPort":2222,"guestPort":22}]},
         "display":{"widthPixels":1920,"heightPixels":1080,"pixelsPerInch":110},
         "account":{"fullName":"A","username":"a"}}
        """#
        let c = try JSONDecoder().decode(VMConfig.self, from: Data(json.utf8))
        XCTAssertEqual(c.version, VMConfig.currentVersion)
        XCTAssertEqual(c.notes, "")
        XCTAssertEqual(c.disks[0].readOnly, false)
        XCTAssertEqual(c.disks[0].interface, .virtio)
        XCTAssertEqual(c.disks[0].caching, .automatic)
        XCTAssertEqual(c.shares[0].readOnly, false)
        XCTAssertEqual(c.network.portForwards[0], .init(hostPort: 2222, guestPort: 22))
        XCTAssertEqual(c.display.widthPixels, 1920)
        XCTAssertTrue(c.display.autoResize)
        XCTAssertEqual(c.features, VMConfig.Features())
        XCTAssertEqual(c.account?.autoLogin, true)
        XCTAssertEqual(c.account?.remoteLogin, true)
        XCTAssertEqual(c.account?.provisioned, false)
    }

    /// Dotted paths of every key, with `[]` for "in each element of this array". Skips the inside of
    /// enums with associated values (`boot`), whose keys are the case itself.
    static func keyPaths(in object: Any, prefix: String) -> [String] {
        var out: [String] = []
        if let dict = object as? [String: Any] {
            for (k, v) in dict {
                let path = prefix.isEmpty ? k : "\(prefix).\(k)"
                out.append(path)
                if k != "boot" { out += keyPaths(in: v, prefix: path) }
            }
        } else if let array = object as? [Any], let first = array.first {
            out += keyPaths(in: first, prefix: prefix + "[]")
        }
        return out
    }

    static func removing(_ path: [String], from object: Any) -> Any {
        guard let head = path.first else { return object }
        let isArray = head.hasSuffix("[]")
        let key = isArray ? String(head.dropLast(2)) : head
        guard var dict = object as? [String: Any] else { return object }
        if path.count == 1 { dict[key] = nil; return dict }
        let rest = Array(path.dropFirst())
        if isArray, let array = dict[key] as? [Any] {
            dict[key] = array.map { removing(rest, from: $0) }
        } else if let child = dict[key] {
            dict[key] = removing(rest, from: child)
        }
        return dict
    }
}
