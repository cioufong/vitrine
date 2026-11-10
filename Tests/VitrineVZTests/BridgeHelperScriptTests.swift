import Foundation
import XCTest
@testable import VitrineVZ

/// The install script root runs is compiled into Vitrine (BridgeHelperScript.swift) rather than read
/// from the user-writable app bundle; Resources/bridge-helper.sh stays the readable source.
final class BridgeHelperScriptTests: XCTestCase {
    func testTheCompiledInScriptIsTheFileByteForByte() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/bridge-helper.sh").standardizedFileURL
        XCTAssertEqual(Data(BridgeHelper.script.utf8), try Data(contentsOf: file),
                       "Sources/VitrineVZ/BridgeHelperScript.swift is out of date: paste Resources/bridge-helper.sh into it")
    }

    func testTheScriptIsPlainASCII() {
        // Nothing for a String literal, the shell or AppleScript to reinterpret.
        XCTAssertTrue(BridgeHelper.script.utf8.allSatisfy { $0 < 0x80 && ($0 >= 0x20 || $0 == 0x0A || $0 == 0x09) })
    }

    /// The command runAsAdmin builds hands sh every argument unchanged, the script included.
    /// (ASCII only: osascript hands non-ASCII text on in decomposed form, which APFS paths tolerate.)
    func testQuotingRoundTripsThroughOsascript() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bridged-quote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tricky = BridgeHelper.script + #"' " \ \\ \" $HOME `id` $(id) ; & | * ? ! %"# + "\n\t\r end"
        // A stand-in script that writes its arguments to files, so nothing goes through osascript's output.
        let echo = #"printf '%s' "$1" > "$3"; printf '%s' "$2" > "$4"; printf '%s' "$0" > "$5""#
        let out = (1...3).map { dir.appendingPathComponent("\($0)").path }
        let command = BridgeHelper.adminCommand(script: echo, [tricky, BridgeHelper.script] + out)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", BridgeHelper.appleScript(command)]
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: out[0])), Data(tricky.utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: out[1])), Data(BridgeHelper.script.utf8))
        XCTAssertEqual(try String(contentsOfFile: out[2], encoding: .utf8), "bridge-helper.sh")
    }
}
