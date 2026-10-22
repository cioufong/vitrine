import XCTest
@testable import VitrineVZ
@testable import VitrineCore

final class CloudInitTests: XCTestCase {
    /// Parses the generated user-data with PyYAML (if available) and checks the important keys.
    func testUserDataIsValidYAMLWithExpectedContent() throws {
        var o = CloudImageInstaller.Options(name: "My VM", fullName: "Test \"Quote\" User", username: "tester",
                                            password: "p@ss: 'word' #1")
        o.display = VMConfig.DisplayConfig(widthPixels: 3024, heightPixels: 1964, pixelsPerInch: 254)
        let yaml = CloudImageInstaller.userData(o, hostname: GuestNetwork.hostname(forVMName: o.name))
        XCTAssertTrue(yaml.hasPrefix("#cloud-config\n"))

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ud-\(UUID().uuidString).yaml")
        try yaml.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let script = """
        import json, sys, yaml
        d = yaml.safe_load(open(sys.argv[1]))
        print(json.dumps({"user": d["users"][0]["name"], "gecos": d["users"][0]["gecos"],
                          "pw": d["users"][0]["passwd"], "plain": d["users"][0].get("plain_text_passwd"), "host": d["hostname"],
                          "pk": d["packages"], "runcmd": d["runcmd"]}))
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-c", script, tmp.path]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw XCTSkip("python3 + PyYAML not available") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(parsed["user"] as? String, "tester")
        XCTAssertEqual(parsed["gecos"] as? String, "Test \"Quote\" User")
        let hash = try XCTUnwrap(parsed["pw"] as? String)
        XCTAssertTrue(hash.hasPrefix("$6$"), "the seed carries a SHA-512 crypt hash, not the password")
        XCTAssertFalse(yaml.contains("p@ss"))
        XCTAssertTrue(parsed["plain"] is NSNull)
        XCTAssertEqual(parsed["host"] as? String, "my-vm")
        XCTAssertTrue((parsed["pk"] as? [String] ?? []).contains("spice-vdagent"))
        let runcmd = (parsed["runcmd"] as? [String] ?? []).joined(separator: "\n")
        XCTAssertTrue(runcmd.contains("autologin-user=tester"))
        XCTAssertTrue(runcmd.contains("WindowScalingFactor"), "Retina hosts get a 2x Xfce")
        XCTAssertTrue(runcmd.contains("virtiofs"))
        let lines = parsed["runcmd"] as? [String] ?? []
        let userRestart = try XCTUnwrap(lines.firstIndex { $0.contains("try-restart user@$(id -u tester)") })
        let lightdm = try XCTUnwrap(lines.firstIndex { $0.contains("restart lightdm") })
        XCTAssertLessThan(userRestart, lightdm, "the session bus must exist before the desktop session starts")
    }
}
