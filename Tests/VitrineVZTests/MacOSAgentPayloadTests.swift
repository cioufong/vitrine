import Foundation
import XCTest
@testable import VitrineVZ

final class MacOSAgentPayloadTests: XCTestCase {
    private var root: URL!
    private let executablePath = "Contents/MacOS/vitrine-agent"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-payload-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    private func fixture(_ name: String, marker: String = "new", executable: Bool = true) throws -> URL {
        let app = root.appendingPathComponent("source").appendingPathComponent(name)
        let binary = app.appendingPathComponent(executablePath)
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: binary.path)
        return app
    }

    private func run(_ executable: String, _ arguments: [String], input: Data? = nil) throws -> (Int32, String) {
        let process = Process(), output = Pipe(), stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output; process.standardError = output; process.standardInput = stdin
        try process.run()
        if let input { try stdin.fileHandleForWriting.write(contentsOf: input) }
        try stdin.fileHandleForWriting.close()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: bytes, as: UTF8.self))
    }

    private func extract(_ payload: Data, into homeFixture: URL) throws {
        let destination = homeFixture.appendingPathComponent(MacOSAgentPayload.extractionRelativePath)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let result = try run("/usr/bin/tar", ["-C", destination.path, "-xf", "-"], input: payload)
        XCTAssertEqual(result.0, 0, result.1)
    }

    private func assertCanonicalPayload(_ app: URL, marker: String) throws {
        let homeFixture = root.appendingPathComponent("destination with spaces")
        try extract(MacOSAgentPayload.archive(from: app), into: homeFixture)
        let installed = homeFixture.appendingPathComponent(MacOSAgentPayload.appRelativePath).appendingPathComponent(executablePath)
        let exists = FileManager.default.fileExists(atPath: installed.path)
        XCTAssertTrue(exists, "canonical executable missing after extraction")
        if exists {
            XCTAssertEqual(try Data(contentsOf: installed), Data(marker.utf8))
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.path))
        }
        let applications = homeFixture.appendingPathComponent("Applications")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), ["VitrineAgent.app"])
    }

    func testCanonicalBundleUsesCanonicalDestination() throws {
        try assertCanonicalPayload(fixture("VitrineAgent.app"), marker: "new")
    }

    func testCustomBasenameAndSpacesUseCanonicalDestination() throws {
        try assertCanonicalPayload(fixture("Diagnostic Agent's App.app"), marker: "new")
    }

    func testCustomReplacementReplacesCanonicalExecutable() throws {
        let homeFixture = root.appendingPathComponent("replacement")
        let installed = homeFixture.appendingPathComponent(MacOSAgentPayload.appRelativePath).appendingPathComponent(executablePath)
        try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: installed)
        try extract(MacOSAgentPayload.archive(from: fixture("Replacement.app", marker: "replacement")), into: homeFixture)
        XCTAssertEqual(try Data(contentsOf: installed), Data("replacement".utf8))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.path))
    }

    func testMissingNonExecutableAndDirectoryPayloadAreRejectedBeforeArchive() throws {
        let missing = root.appendingPathComponent("missing.app")
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        XCTAssertThrowsError(try MacOSAgentPayload.archive(from: missing))
        XCTAssertThrowsError(try MacOSAgentPayload.archive(from: fixture("NotExecutable.app", executable: false)))
        let directory = root.appendingPathComponent("Directory.app")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(executablePath), withIntermediateDirectories: true)
        XCTAssertThrowsError(try MacOSAgentPayload.archive(from: directory))
        let linked = root.appendingPathComponent("Linked.app")
        try FileManager.default.createDirectory(at: linked.appendingPathComponent(executablePath).deletingLastPathComponent(), withIntermediateDirectories: true)
        let valid = try fixture("LinkTarget.app").appendingPathComponent(executablePath)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent(executablePath), withDestinationURL: valid)
        XCTAssertThrowsError(try MacOSAgentPayload.archive(from: linked))
    }

    private func guardResult(_ app: URL, bootstrap: String = "printf 'bootstrap\\n'") throws -> (Int32, String) {
        // APP is a fixture-only variable; the host HOME is never changed and no launchctl is invoked.
        let script = "set -e\nAPP=\"$1\"\n" + MacOSAgentPayload.remoteExecutableGuard + "\n" + bootstrap + "\nprintf 'installed\\n'\n"
        return try run("/bin/bash", ["-c", script, "payload-fixture", app.path])
    }

    func testSymlinkedBundleDirectoriesAreRejectedBeforeArchive() throws {
        let valid = try fixture("AncestorLinkTarget.app")
        let contentsLink = root.appendingPathComponent("ContentsLink.app")
        try FileManager.default.createDirectory(at: contentsLink, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: contentsLink.appendingPathComponent("Contents"),
                                                  withDestinationURL: valid.appendingPathComponent("Contents"))
        XCTAssertThrowsError(try MacOSAgentPayload.archive(from: contentsLink))
        let macOSLink = root.appendingPathComponent("MacOSLink.app")
        try FileManager.default.createDirectory(at: macOSLink.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: macOSLink.appendingPathComponent("Contents/MacOS"),
                                                  withDestinationURL: valid.appendingPathComponent("Contents/MacOS"))
        XCTAssertThrowsError(try MacOSAgentPayload.archive(from: macOSLink))
    }

    func testRemoteGuardStopsBeforeBootstrapAndInstalledForInvalidExecutable() throws {
        let missing = root.appendingPathComponent("missing-remote.app")
        let nonExecutable = try fixture("NonExecutableRemote.app", executable: false)
        let directory = root.appendingPathComponent("DirectoryRemote.app")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(executablePath), withIntermediateDirectories: true)
        for app in [missing, nonExecutable, directory] {
            let result = try guardResult(app)
            XCTAssertNotEqual(result.0, 0)
            XCTAssertFalse(result.1.contains("bootstrap"))
            XCTAssertFalse(result.1.contains("installed"))
        }
    }

    func testRemoteGuardAllowsExecutableAndPropagatesBootstrapFailure() throws {
        let app = try fixture("ValidRemote.app")
        let success = try guardResult(app)
        XCTAssertEqual(success.0, 0); XCTAssertTrue(success.1.contains("installed"))
        let failure = try guardResult(app, bootstrap: "false")
        XCTAssertNotEqual(failure.0, 0); XCTAssertFalse(failure.1.contains("installed"))
    }
}
