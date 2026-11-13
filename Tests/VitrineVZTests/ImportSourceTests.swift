import Foundation
import XCTest
@testable import VitrineVZ
@testable import VitrineCore

/// Which importer the app hands a dropped or chosen file to (the same dispatch as `vitrinectl import`).
final class ImportSourceTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("vitrine-importsource-\(UUID())").resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    @discardableResult
    private func file(_ path: String, _ text: String = "x") throws -> URL {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func folder(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testWholeVMFilesAndBundles() throws {
        XCTAssertEqual(try ImportSource.classify(try file("a.ova")), .wholeVM(.ova))
        XCTAssertEqual(try ImportSource.classify(try file("b/b.ovf")), .wholeVM(.ovf))
        XCTAssertEqual(try ImportSource.classify(try file("c/c.vmx")), .wholeVM(.vmware))
        XCTAssertEqual(try ImportSource.classify(try file("d/D.VBOX")), .wholeVM(.virtualBox))
        // Bundles are plain folders when Parallels or VMware isn't installed.
        let pvm = try folder("Debian.pvm")
        try file("Debian.pvm/config.pvs")
        XCTAssertEqual(try ImportSource.classify(pvm), .wholeVM(.parallels))
        try file("Win.vmwarevm/Win.vmx")
        XCTAssertEqual(try ImportSource.classify(root.appendingPathComponent("Win.vmwarevm")), .wholeVM(.vmware))
        // A plain folder holding a VM's configuration is that VM.
        try file("vbox-folder/machine.vbox")
        XCTAssertEqual(try ImportSource.classify(root.appendingPathComponent("vbox-folder")), .wholeVM(.virtualBox))
    }

    func testUTMAndDiskImages() throws {
        XCTAssertEqual(try ImportSource.classify(try folder("Ubuntu.utm")), .utm)
        for ext in ["qcow2", "vmdk", "vhd", "vhdx", "vdi", "img", "raw", "QCOW2"] {
            XCTAssertEqual(try ImportSource.classify(try file("disk.\(ext)")), .diskImage, ext)
        }
        // A .utm that is a file, or a folder named like a disk image, is neither.
        XCTAssertNil(try ImportSource.classify(try file("odd.utm")))
        XCTAssertNil(try ImportSource.classify(try folder("folder.qcow2")))
    }

    func testOtherThingsAreNotImportable() throws {
        XCTAssertNil(try ImportSource.classify(try file("installer.iso")))
        XCTAssertNil(try ImportSource.classify(try file("notes.txt")))
        XCTAssertNil(try ImportSource.classify(try folder("Documents")))
        // A Vitrine VM isn't imported into Vitrine.
        XCTAssertNil(try ImportSource.classify(try folder("Mine.vitrinevm")))
    }

    func testUnreadableVMFoldersAndMissingFilesThrow() throws {
        try file("two/a.vmx"); try file("two/b.vmx")
        XCTAssertThrowsError(try ImportSource.classify(root.appendingPathComponent("two")))
        XCTAssertThrowsError(try ImportSource.classify(try folder("Empty.vmwarevm")))
        XCTAssertThrowsError(try ImportSource.classify(root.appendingPathComponent("gone.qcow2")))
    }

    func testOpenPanelSelection() throws {
        XCTAssertTrue(ImportSource.isSelectable(try file("x.ova")))
        XCTAssertTrue(ImportSource.isSelectable(try file("x.vdi")))
        XCTAssertTrue(ImportSource.isSelectable(try folder("Any Folder")))
        XCTAssertFalse(ImportSource.isSelectable(try file("x.iso")))
        XCTAssertFalse(ImportSource.isSelectable(root.appendingPathComponent("missing.ova")))
        for ext in ["ova", "ovf", "vmx", "vmwarevm", "pvm", "vbox", "utm", "qcow2", "vmdk", "vhd", "vhdx", "vdi", "img", "raw"] {
            XCTAssertTrue(ImportSource.allExtensions.contains(ext), ext)
        }
    }

    func testSuggestedNameIsAValidVMName() {
        XCTAssertEqual(ImportSource.suggestedName(for: URL(fileURLWithPath: "/x/debian-12 (arm64).qcow2")), "debian-12-arm64")
        XCTAssertTrue(VMCreationJob.isValidVMName(ImportSource.suggestedName(for: URL(fileURLWithPath: "/x/日本語.vmdk"))))
    }
}
