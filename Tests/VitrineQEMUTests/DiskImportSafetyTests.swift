import XCTest
@testable import VitrineQEMU
@testable import VitrineCore

final class DiskImportSafetyTests: XCTestCase {
    let image = URL(fileURLWithPath: "/tmp/vm/Data/disk.qcow2")

    func testReferencedFilesAreReadFromQemuImgInfo() {
        let json: [String: Any] = [
            "backing-filename": "/etc/master.passwd",
            "format-specific": ["type": "qcow2", "data": ["data-file": "/Users/someone/secret.raw"]],
        ]
        let qcow = DiskImport.referencedFiles(json)
        XCTAssertEqual(qcow.backing, ["/etc/master.passwd", "/Users/someone/secret.raw"])
        XCTAssertEqual(qcow.extents, [])
        let vmdk: [String: Any] = [
            "backing-filename": "base.vmdk",
            "format-specific": ["type": "vmdk", "data": ["extents": [["filename": "a-s001.vmdk"], ["filename": "/etc/hosts"]]]],
        ]
        XCTAssertEqual(DiskImport.referencedFiles(vmdk).backing, ["base.vmdk"])
        XCTAssertEqual(DiskImport.referencedFiles(vmdk).extents, ["a-s001.vmdk", "/etc/hosts"])
    }

    func testBackingAndDataFilesAreRefused() {
        let backed = DiskImport.Info(format: "qcow2", virtualSize: 1, backingFiles: ["/etc/master.passwd"])
        XCTAssertThrowsError(try DiskImport.checkSelfContained(image, backed))
        // Even one next to the image: a backing chain is never flattened implicitly.
        let sibling = DiskImport.Info(format: "qcow2", virtualSize: 1, backingFiles: ["base.qcow2"])
        XCTAssertThrowsError(try DiskImport.checkSelfContained(image, sibling))
        XCTAssertNoThrow(try DiskImport.checkSelfContained(image, .init(format: "qcow2", virtualSize: 1)))
    }

    func testVMDKExtentsMustStayNextToTheImage() {
        let disk = URL(fileURLWithPath: "/tmp/vm/Data/disk.vmdk")
        XCTAssertNoThrow(try DiskImport.checkSelfContained(disk, .init(format: "vmdk", virtualSize: 1,
                                                                        extents: ["/tmp/vm/Data/disk.vmdk"])))
        XCTAssertNoThrow(try DiskImport.checkSelfContained(disk, .init(format: "vmdk", virtualSize: 1,
                                                                        extents: ["disk-s001.vmdk", "disk-s002.vmdk"])))
        XCTAssertThrowsError(try DiskImport.checkSelfContained(disk, .init(format: "vmdk", virtualSize: 1,
                                                                            extents: ["../../../etc/hosts"])))
        XCTAssertThrowsError(try DiskImport.checkSelfContained(disk, .init(format: "vmdk", virtualSize: 1,
                                                                            extents: ["/dev/disk0"])))
        // A child VMDK's parent sits next to it but may itself read from anywhere.
        XCTAssertThrowsError(try DiskImport.checkSelfContained(disk, .init(format: "vmdk", virtualSize: 1,
                                                                            backingFiles: ["base.vmdk"],
                                                                            extents: ["disk.vmdk"])))
    }
}
