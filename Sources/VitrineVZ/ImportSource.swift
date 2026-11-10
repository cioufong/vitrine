import Foundation
import VitrineCore

/// What a file or folder handed to Vitrine for import is, and so which importer takes it: the same
/// dispatch as `vitrinectl import` (whole VMs first, then UTM bundles, then single disk images).
public enum ImportSource: Equatable, Sendable {
    /// An OVA/OVF package or a VMware, Parallels or VirtualBox VM (`WholeVMImporter`).
    case wholeVM(ImportPlan.SourceFormat)
    /// A UTM virtual machine bundle (`UTMImporter`).
    case utm
    /// A single disk image (`VMImporter.importDisk`).
    case diskImage

    /// Extensions of whole-VM sources (files and bundle folders) that `WholeVMImporter` reads.
    public static let wholeVMExtensions = ["ova", "ovf", "vmx", "vmwarevm", "pvm", "vbox"]
    /// Disk image files `VMImporter.importDisk` converts with qemu-img.
    public static let diskImageExtensions = ["qcow2", "qcow", "vmdk", "vhd", "vhdx", "vdi", "img", "raw"]
    /// Every extension an open panel should offer (folders are offered as well: a .pvm or
    /// .vmwarevm is a plain folder when Parallels or VMware isn't installed).
    public static let allExtensions = wholeVMExtensions + ["utm"] + diskImageExtensions

    /// The kind of `url`, or nil when it is none Vitrine imports (a plain folder without a VM in it,
    /// an ISO, …). Throws when it looks like a VM that can't be read as one (a folder with two .vmx
    /// files, a .vmwarevm without one) or doesn't exist.
    public static func classify(_ url: URL) throws -> ImportSource? {
        if let format = try WholeVMImporter.detectFormat(url) { return .wholeVM(format) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw VitrineError.fileNotFound(url.path)
        }
        let ext = url.pathExtension.lowercased()
        if isDir.boolValue { return ext == "utm" ? .utm : nil }
        return diskImageExtensions.contains(ext) ? .diskImage : nil
    }

    /// Whether an open panel should let the user pick `url`: a source of a known kind, or a folder
    /// (to look inside, or to import when it holds a VM).
    public static func isSelectable(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        return isDir.boolValue || allExtensions.contains(url.pathExtension.lowercased())
    }

    /// The name a disk image import suggests: its file name made into a valid VM name.
    public static func suggestedName(for url: URL) -> String {
        VMImportName.sanitize(url.deletingPathExtension().lastPathComponent)
    }
}
