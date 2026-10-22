import Foundation
import VitrineCore

/// Installs and removes `vitrine-bridged` (see Resources/bridge-helper.sh). macOS asks for an
/// administrator's password in its own dialog; Vitrine never sees it.
public enum BridgeHelper {
    public static var isInstalled: Bool { BridgeSockets.helperInstalled }

    public static func install() throws {
        guard let binary = BuildLayout.executable(named: "vitrine-bridged") else {
            throw VitrineError.backend("vitrine-bridged is missing from this build of Vitrine")
        }
        try runAsAdmin(["install", binary.path, "\(getuid())"])
    }

    public static func uninstall() throws {
        try runAsAdmin(["uninstall"])
    }

    private static func runAsAdmin(_ args: [String]) throws {
        guard let script = BuildLayout.resource(named: "bridge-helper.sh") else {
            throw VitrineError.backend("bridge-helper.sh is missing from this build of Vitrine")
        }
        let command = ([script.path] + args).map(shellQuote).joined(separator: " ")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "do shell script \"/bin/sh \(appleScriptEscape(command))\" with administrator privileges"]
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
