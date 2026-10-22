import XCTest
@testable import VitrineQEMU
@testable import VitrineCore

final class WindowsUnattendTests: XCTestCase {
    func options(_ arch: VMConfig.Architecture) -> WindowsUnattend.Options {
        WindowsUnattend.Options(architecture: arch, computerName: WindowsUnattend.computerName(forVMName: "My Windows 11 VM"),
                                fullName: "Ann <Admin> & Co", username: "ann", password: "p\"w'd<&>")
    }

    func testXMLIsWellFormedAndEscaped() throws {
        let xml = WindowsUnattend.xml(options(.aarch64))
        let doc = try XMLDocument(xmlString: xml, options: [])
        let ns = ["u": "urn:schemas-microsoft-com:unattend"]
        _ = ns
        // Every component targets arm64.
        let comps = try doc.nodes(forXPath: "//*[local-name()='component']")
        XCTAssertGreaterThan(comps.count, 5)
        for c in comps {
            XCTAssertEqual((c as? XMLElement)?.attribute(forName: "processorArchitecture")?.stringValue, "arm64")
        }
        // vioscsi is loaded before Setup looks for its (virtio-scsi) media.
        let first = try doc.nodes(forXPath: "//*[local-name()='RunSynchronousCommand'][*[local-name()='Order']='1']/*[local-name()='Path']").first?.stringValue
        XCTAssertTrue(first?.contains(#"drvload %d:\winpe\vioscsi\vioscsi.inf"#) ?? false)
        let name = try doc.nodes(forXPath: "//*[local-name()='LocalAccount']/*[local-name()='Name']").first?.stringValue
        XCTAssertEqual(name, "ann")
        let pw = try doc.nodes(forXPath: "//*[local-name()='LocalAccount']//*[local-name()='Value']").first?.stringValue
        XCTAssertEqual(pw, PasswordHash.unattendObfuscated("p\"w'd<&>"))
        XCTAssertFalse(xml.contains("p&quot;w"), "the password itself is not in the answer file")
        XCTAssertFalse(xml.contains("<PlainText>true"))
        let full = try doc.nodes(forXPath: "//*[local-name()='DisplayName']").first?.stringValue
        XCTAssertEqual(full, "Ann <Admin> & Co")
        XCTAssertEqual(try doc.nodes(forXPath: "//*[local-name()='ComputerName']").first?.stringValue, "MY-WINDOWS-11-V")
        XCTAssertTrue(xml.contains("BypassNRO"))
        XCTAssertTrue(xml.contains(#"\vitrine\setup.cmd"#))
    }

    func testX64Architecture() throws {
        let doc = try XMLDocument(xmlString: WindowsUnattend.xml(options(.x86_64)), options: [])
        let comps = try doc.nodes(forXPath: "//*[local-name()='component']")
        XCTAssertTrue(comps.allSatisfy { ($0 as? XMLElement)?.attribute(forName: "processorArchitecture")?.stringValue == "amd64" })
    }

    func testSeedISOContainsAnswerFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("winseed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let iso = dir.appendingPathComponent("seed.iso")
        try WindowsUnattend.makeSeedISO(at: iso, options: options(.aarch64), driversDirectory: nil, agentExecutable: nil)
        let data = try Data(contentsOf: iso)
        XCTAssertGreaterThan(data.count, 32 * 1024)
        XCTAssertNotNil(data.range(of: Data("AUTOUNATTEND".utf8)) ?? data.range(of: Data("autounattend".utf8)))
    }
}
