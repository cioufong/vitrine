import Foundation

/// Stores the guest account password inside the VM bundle (`guest-account.secret`, mode 0600).
///
/// A file (rather than the login Keychain) because Vitrine.app and vitrinectl are separately signed
/// and must both read it without prompts, and because clones should keep working with the same
/// guest account. Security is equivalent to a Keychain item readable by any of the user's apps;
/// the bundle lives in the user's (FileVault-protected) home directory.
public enum GuestCredentialStore {
    static let fileName = "guest-account.secret"

    static func url(_ bundle: VMBundle) -> URL { bundle.url.appendingPathComponent(fileName) }

    public static func setPassword(_ password: String, in bundle: VMBundle) throws {
        let url = url(bundle)
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(password.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw VitrineError.io("cannot write \(url.path)")
        }
    }

    public static func password(in bundle: VMBundle) -> String? {
        guard let data = try? Data(contentsOf: url(bundle)), var s = String(data: data, encoding: .utf8) else { return nil }
        while s.hasSuffix("\n") || s.hasSuffix("\r") { s.removeLast() }
        return s
    }

    public static func deletePassword(in bundle: VMBundle) {
        try? FileManager.default.removeItem(at: url(bundle))
    }
}
