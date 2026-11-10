import Foundation
import Security
import VitrineCore

/// Installs and removes `vitrine-bridged` (see Resources/bridge-helper.sh). macOS asks for an
/// administrator's password in its own dialog; Vitrine never sees it.
///
/// The binary comes from the app bundle, which the user (and anything running as the user) can
/// write. So the script root runs is compiled into Vitrine (`BridgeHelper.script`, the text of
/// Resources/bridge-helper.sh) rather than read from the bundle, and it checks the binary's
/// signature only after copying it somewhere only root can reach, against a requirement built
/// here: identifier `vitrine-bridged` and the binary's cdhash, plus this process's Team ID when it
/// is signed with one. Ad-hoc builds get no identity anchor (anything running as the user could
/// re-sign the whole bundle), only the guarantee that root installs exactly the file this process
/// looked at.
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

    /// The signing identifier build-app.sh gives the helper, and the requirement demands.
    static let identifier = "vitrine-bridged"

    /// `identifier "vitrine-bridged" and cdhash H"…"`, anchored to Apple-issued certificates of
    /// `teamID` when there is one.
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
        // A plain `swift build` leaves the linker's identifier (vitrine-bridged-<hash>); build-app.sh signs it properly.
        guard dict[kSecCodeInfoIdentifier as String] as? String == identifier else {
            throw VitrineError.backend("\(binary.path) is not signed as \(identifier); build Vitrine with scripts/build-app.sh")
        }
        let pin = "identifier \"\(identifier)\" and cdhash H\"\(cdhash.map { String(format: "%02x", $0) }.joined())\""
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

    /// The shell command root runs: the script's text, not a path, so root never reads a file in
    /// the bundle except the binary it verifies.
    static func adminCommand(script: String, _ args: [String]) -> String {
        (["/bin/sh", "-c", script, "bridge-helper.sh"] + args).map(shellQuote).joined(separator: " ")
    }

    private static func runAsAdmin(_ args: [String]) throws {
        let command = adminCommand(script: script, args)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", appleScript(command) + " with administrator privileges"]
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
    /// `do shell script "<command>"`: runAsAdmin adds `with administrator privileges`.
    static func appleScript(_ command: String) -> String { "do shell script \"\(appleScriptEscape(command))\"" }
    /// For the body of an AppleScript string literal, where only `\` and `"` are special.
    static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
