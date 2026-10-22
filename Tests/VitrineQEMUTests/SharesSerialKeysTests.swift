import XCTest
@testable import VitrineQEMU
@testable import VitrineCore

final class SharesSerialKeysTests: XCTestCase {
    let env = QEMUEnvironment(binDirectory: URL(fileURLWithPath: "/opt/homebrew/bin"),
                              shareDirectory: URL(fileURLWithPath: "/opt/homebrew/share/qemu"))
    let sockets = QEMUSockets(directory: URL(fileURLWithPath: "/tmp/s"))
    let bundle = VMBundle(url: URL(fileURLWithPath: "/tmp/vm.vitrinevm"))

    private func config(_ os: VMConfig.GuestOS) -> VMConfig {
        var c = VMConfig(name: "t", guestOS: os, cpuCount: 2, memoryMiB: 2048)
        c.backend = .qemu
        c.disks = [.init(path: "disk.img")]
        c.shares = [.init(hostPath: "/Users/alice/My Projects", name: "My Projects"),
                    .init(hostPath: "/Users/alice/Docs", name: "Docs", readOnly: true)]
        return c
    }

    private func args(_ c: VMConfig) -> String {
        QEMUArguments.build(config: c, bundle: bundle, env: env, sockets: sockets, options: .init(withTPM: false)).joined(separator: " ")
    }

    func testLinuxGuestsGetOneNinePExportPerFolder() {
        let a = args(config(.linux))
        XCTAssertTrue(a.contains("-fsdev local,id=fs0,path=/Users/alice/My Projects,security_model=none -device virtio-9p-pci,fsdev=fs0,mount_tag=My_Projects"))
        XCTAssertTrue(a.contains("local,id=fs1,path=/Users/alice/Docs,security_model=none,readonly=on"))
        XCTAssertFalse(args(config(.windows)).contains("virtio-9p"), "Windows gets shares over SMB")
    }

    func testMountTagsAreValidAndUnique() throws {
        XCTAssertEqual(VMConfig.SharedDirectory(hostPath: "/a", name: "Café & Co").mountTag, "Caf____Co")
        XCTAssertEqual(VMConfig.SharedDirectory(hostPath: "/a", name: String(repeating: "x", count: 40)).mountTag.count, 31)
        var c = config(.linux)
        c.shares = [.init(hostPath: "/a", name: "a b"), .init(hostPath: "/b", name: "a_b")]
        XCTAssertThrowsError(try c.validate())
        c.shares = [.init(hostPath: "/a,b", name: "x")]
        XCTAssertThrowsError(try c.validate())
    }

    func testSerialConsoleSocketAndOptionalGDBStub() throws {
        var c = config(.linux)
        let a = args(c)
        XCTAssertTrue(a.contains("-chardev socket,id=ser0,path=/tmp/s/serial.sock,server=on,wait=off,logfile=/tmp/vm.vitrinevm/console.log,logappend=on -serial chardev:ser0"))
        XCTAssertFalse(a.contains("-gdb"))
        c.features.gdbPort = 1234
        XCTAssertTrue(args(c).contains("-gdb tcp:127.0.0.1:1234"))
        c.features.gdbPort = 80
        XCTAssertThrowsError(try c.validate())
        c.features.gdbPort = 1234
        c.backend = .vz
        c.shares = []
        XCTAssertThrowsError(try c.validate(), "VZ has no GDB stub")
    }

    func testUSKeyboardChords() throws {
        XCTAssertEqual(try QEMUKeyboard.chords(for: "aA1!\n"), [["a"], ["shift", "a"], ["1"], ["shift", "1"], ["ret"]])
        XCTAssertEqual(QEMUKeyboard.chord(for: "|"), ["shift", "backslash"])
        XCTAssertThrowsError(try QEMUKeyboard.chords(for: "é"))
    }
}
