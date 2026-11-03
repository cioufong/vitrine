import Foundation
import Security
import VitrineCore

/// Installs and removes `vitrine-bridged` (see Resources/bridge-helper.sh). macOS asks for an
/// administrator's password in its own dialog; Vitrine never sees it.
///
/// Both files come from the app bundle, which the user (and anything running as the user) can
/// write. So the script runs from memory rather than from its file, and it checks the binary's
/// signature only after copying it somewhere root owns, against a requirement built here: the
/// binary's cdhash, plus this process's Team ID when it is signed with one. Ad-hoc builds get no
/// identity anchor (anything running as the user could re-sign the whole bundle), only the
/// guarantee that root installs exactly the file this process looked at.
public enum BridgeHelper {
    public static var isInstalled: Bool { BridgeSockets.helperInstalled }

    public static func install() throws {
        guard let binary = BuildLayout.executable(named: "vitrine-bridged") else {
            throw VitrineError.backend("vitrine-bridged is missing from this build of Vitrine")
        }
        let requirement = try codeRequirement(for: binary, teamID: ownTeamID())
        try runAsAdmin(["install", binary.path, "\(getuid())", requirement])
    }

    public static func uninstall() throws {
        try runAsAdmin(["uninstall"])
    }

    /// `cdhash H"…"`, anchored to Apple-issued certificates of `teamID` when there is one.
    static func codeRequirement(for binary: URL, teamID: String?) throws -> String {
        // Each slice of a universal binary has its own cdhash; build-app.sh builds this Mac's only.
        if let head = try? FileHandle(forReadingFrom: binary).read(upToCount: 4), head.count == 4,
           [Data([0xCA, 0xFE, 0xBA, 0xBE]), Data([0xCA, 0xFE, 0xBA, 0xBF])].contains(head) {
            throw VitrineError.backend("\(binary.path) is a universal binary; build vitrine-bridged for this Mac only")
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(binary as CFURL, [], &code) == errSecSuccess, let code else {
            throw VitrineError.backend("cannot read the signature of \(binary.path)")
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let cdhash = dict[kSecCodeInfoUnique as String] as? Data else {
            throw VitrineError.backend("\(binary.path) is not code-signed")
        }
        let pin = "cdhash H\"\(cdhash.map { String(format: "%02x", $0) }.joined())\""
        guard let teamID else { return pin }
        guard teamID.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            throw VitrineError.backend("unexpected Team ID \(teamID)")
        }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and \(pin)"
    }

    /// The Team ID this process is signed with, or nil (ad-hoc and unsigned builds).
    static func ownTeamID() -> String? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var staticMe: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticMe, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static func helperScript() throws -> String {
        guard let url = BuildLayout.resource(named: "bridge-helper.sh"),
              let script = try? String(contentsOf: url, encoding: .utf8) else {
            throw VitrineError.backend("bridge-helper.sh is missing from this build of Vitrine")
        }
        return script
    }

    /// The shell command root runs: the script's text, not its path, so root never reads a file
    /// in the bundle except the binary it verifies.
    static func adminCommand(script: String, _ args: [String]) -> String {
        (["/bin/sh", "-c", script, "bridge-helper.sh"] + args).map(shellQuote).joined(separator: " ")
    }

    private static func runAsAdmin(_ args: [String]) throws {
        let command = adminCommand(script: try helperScript(), args)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "do shell script \"\(appleScriptEscape(command))\" with administrator privileges"]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if message.contains("-128") { throw VitrineError.backend("cancelled") }
            throw VitrineError.backend(message.isEmpty ? "the bridge helper script failed" : message)
        }
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
