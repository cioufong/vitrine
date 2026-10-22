import Foundation

// macOS-only payload layout. Linux keeps the existing top-level package archive.
enum MacOSAgentPayload {
    static let appRelativePath = "Applications/VitrineAgent.app"
    /// Where camera support moves it, relative to / (system extensions only activate from there).
    static let systemAppRelativePath = "Applications/VitrineAgent.app"
    static let extractionRelativePath = appRelativePath
    static let receiveCommand = #"mkdir -p "$HOME/Applications" && rm -rf "$HOME/\#(appRelativePath)" && mkdir -p "$HOME/\#(extractionRelativePath)" && tar -C "$HOME/\#(extractionRelativePath)" -xf -"#
    static let remoteExecutableGuard = #"""
    if [ ! -f "$APP/Contents/MacOS/vitrine-agent" ] || [ ! -x "$APP/Contents/MacOS/vitrine-agent" ]; then
      printf '%s\n' 'macOS agent executable missing or not executable' >&2
      exit 1
    fi
    """#

    enum Failure: LocalizedError {
        case invalidExecutable, archiveFailed
        var errorDescription: String? {
            switch self {
            case .invalidExecutable: return "macOS agent bundle must contain a regular executable Contents/MacOS/vitrine-agent"
            case .archiveFailed: return "could not archive the macOS agent bundle"
            }
        }
    }

    static func archive(from app: URL) throws -> Data {
        let executable = app.appendingPathComponent("Contents/MacOS/vitrine-agent")
        let files = FileManager.default
        // tar preserves directory symlinks rather than archiving their contents.
        for component in ["Contents", "Contents/MacOS"] {
            guard let attributes = try? files.attributesOfItem(atPath: app.appendingPathComponent(component).path),
                  attributes[.type] as? FileAttributeType == .typeDirectory else { throw Failure.invalidExecutable }
        }
        guard let attributes = try? files.attributesOfItem(atPath: executable.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              files.isExecutableFile(atPath: executable.path) else { throw Failure.invalidExecutable }
        let tar = Process(), output = Pipe()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["--no-mac-metadata", "-C", app.path, "-cf", "-", "."]
        tar.standardOutput = output
        try tar.run()
        let payload = output.fileHandleForReading.readDataToEndOfFile()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw Failure.archiveFailed }
        return payload
    }
}
