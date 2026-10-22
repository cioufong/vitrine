import Foundation

/// Where this build keeps its helper executables and packaged files: inside Vitrine.app, or in a
/// development checkout next to the binary SwiftPM built (`.build/<config>/`) and in `dist/`.
public enum BuildLayout {
    /// A helper executable: an auxiliary executable of the app bundle, the running binary itself,
    /// or (development builds) a binary next to it.
    public static func executable(named name: String) -> URL? {
        let fm = FileManager.default
        if let url = Bundle.main.url(forAuxiliaryExecutable: name), fm.isExecutableFile(atPath: url.path) { return url }
        guard let exe = Bundle.main.executableURL else { return nil }
        if exe.lastPathComponent == name { return exe }
        let sibling = exe.deletingLastPathComponent().appendingPathComponent(name)
        return fm.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }

    /// Where packaged guest agents are looked for, in order: the app's Resources, the running
    /// binary's directory, then `dist` in that directory and its parents (a development checkout:
    /// <repo>/dist relative to .build/…/debug/vitrinectl).
    public static func distRoots() -> [URL] {
        var roots: [URL] = []
        if let res = Bundle.main.resourceURL { roots.append(res) }
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        roots.append(exeDir)
        var dir = exeDir
        for _ in 0..<6 { roots.append(dir.appendingPathComponent("dist")); dir = dir.deletingLastPathComponent() }
        return roots
    }

    /// The first `relativePath` under `distRoots()` that `isValid` accepts (by default: that exists).
    public static func distItem(_ relativePath: String,
                                where isValid: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL? {
        distRoots().map { $0.appendingPathComponent(relativePath) }.first(where: isValid)
    }

    /// A file in the app's Resources, or (development builds) in the repository's Resources folder.
    public static func resource(named name: String) -> URL? {
        if let url = Bundle.main.url(forResource: (name as NSString).deletingPathExtension,
                                     withExtension: (name as NSString).pathExtension) { return url }
        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<5 {
            guard let d = dir else { break }
            for candidate in [d.appendingPathComponent("Resources/\(name)"), d.appendingPathComponent("../Resources/\(name)")] {
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate.standardizedFileURL }
            }
            dir = d.deletingLastPathComponent()
        }
        return nil
    }
}
