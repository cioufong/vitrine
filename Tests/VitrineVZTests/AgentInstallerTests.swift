import XCTest
@testable import VitrineVZ
import VitrineCore

final class AgentInstallerTests: XCTestCase {
    func testScriptCommandShapes() {
        let script = "echo hi\n"
        let b64 = Data(script.utf8).base64EncodedString()
        XCTAssertEqual(AgentInstaller.scriptCommand(script, asRoot: true, on: .macOS),
                       "f=$(mktemp) && echo \(b64) | /usr/bin/base64 -D > \"$f\" && sudo -S -p '' /bin/bash \"$f\" </dev/stdin; rc=$?; rm -f \"$f\"; exit $rc")
        XCTAssertEqual(AgentInstaller.scriptCommand(script, asRoot: true, on: .linux),
                       "f=$(mktemp) && echo \(b64) | base64 -d > \"$f\" && sudo -S -p '' /bin/bash \"$f\" </dev/stdin; rc=$?; rm -f \"$f\"; exit $rc")
        XCTAssertEqual(AgentInstaller.scriptCommand(script, asRoot: false, on: .macOS),
                       "f=$(mktemp) && echo \(b64) | /usr/bin/base64 -D > \"$f\" && /bin/bash \"$f\" </dev/stdin; rc=$?; rm -f \"$f\"; exit $rc")
    }

    /// The Mac's time zone goes into the script only when it looks like an IANA name.
    func testFinalizeSetupScriptTimeZone() {
        XCTAssertTrue(AgentInstaller.finalizeSetupScript(timeZone: "Asia/Taipei").contains(#"Z="Asia/Taipei""#))
        XCTAssertTrue(AgentInstaller.finalizeSetupScript(timeZone: "America/Argentina/Buenos_Aires").contains(#"Z="America/Argentina/Buenos_Aires""#))
        for bad in ["", "Asia/Taipei\"; rm -rf /", "../../etc/passwd", "Asia/$(id)"] {
            XCTAssertTrue(AgentInstaller.finalizeSetupScript(timeZone: bad).contains(#"Z="""#), bad)
        }
    }

    /// The macOS form runs here as it would in a macOS guest (no sudo) and passes on the exit status.
    func testScriptCommandRunsOnMacOS() throws {
        signal(SIGPIPE, SIG_IGN) // a script that exits early must fail the test, not kill it
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", AgentInstaller.scriptCommand("read line; echo \"got $line\"; exit 3\n", asRoot: false, on: .macOS)]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        try p.run()
        try input.fileHandleForWriting.write(contentsOf: Data("secret\n".utf8))
        try input.fileHandleForWriting.close()
        let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        XCTAssertEqual(out, "got secret\n")
        XCTAssertEqual(p.terminationStatus, 3)
    }
}
