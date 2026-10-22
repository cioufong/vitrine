import XCTest
@testable import VitrineVZ
@testable import VitrineCore

final class VMControlTests: XCTestCase {
    func testRequestResponseOverSocket() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctl-\(UUID().uuidString.prefix(6)).vitrinevm")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = VMBundle(url: dir)
        let server = try VMControlServer(bundle: bundle) { request in
            switch request.op {
            case .usbAttach:
                return VMControl.Response(ok: true, attached: AttachedUSB(id: "usb7", attachment: request.attachment!))
            default:
                return VMControl.Response(ok: false, error: "nope \(request.op.rawValue)")
            }
        }
        defer { server.stop() }
        let attachment = USBAttachment.image(path: "/tmp/a b.img", readOnly: true)
        let r = try await Task.detached { try VMControl.send(.init(op: .usbAttach, attachment: attachment), to: bundle) }.value
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.attached, AttachedUSB(id: "usb7", attachment: attachment))
        let r2 = try await Task.detached { try VMControl.send(.init(op: .usbList), to: bundle) }.value
        XCTAssertEqual(r2.error, "nope usbList")
        let mode = try FileManager.default.attributesOfItem(atPath: VMControl.socketURL(for: bundle).path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        server.stop()
        XCTAssertThrowsError(try VMControl.send(.init(op: .ping), to: bundle))
    }

    @MainActor
    func testPortEditsUseTheLockAndPreserveFreshConfiguration() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ports-\(UUID()).vitrinevm")
        var c = VMConfig(name: "ports", guestOS: .linux, cpuCount: 1, memoryMiB: 2048)
        c.disks = [.init(path: "disk.img")]
        let b = try VMBundle.create(at: dir, config: c)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(count: 4096).write(to: b.resolve("disk.img"))
        let controller = try VirtualMachineController(bundle: b)
        c.display.widthPixels = 1440
        try b.saveConfig(c)
        let forward = try XCTUnwrap(VMConfig.PortForward(spec: "8080:80"))
        try controller.updatePortForwards { $0.append(forward) }
        XCTAssertEqual(try b.loadConfig().network.portForwards, [forward])
        XCTAssertEqual(try b.loadConfig().display.widthPixels, 1440)
        XCTAssertFalse(b.holdsRunLock)

        try b.acquireRunLock(role: .operation)
        defer { b.releaseRunLock() }
        XCTAssertThrowsError(try controller.updatePortForwards { $0.removeAll() })
        let response = await controller.handleControl(.init(op: .portRemove, hostPort: 8080))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(try b.loadConfig().network.portForwards, [forward])
        let request = VMControl.Request(op: .portAdd, portForward: forward)
        XCTAssertEqual(try JSONDecoder().decode(VMControl.Request.self, from: JSONEncoder().encode(request)), request)
    }

    func testSSHTargetRequiresARunningOwner() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-\(UUID()).vitrinevm")
        let b = try VMBundle.create(at: dir, config: VMConfig(name: "ssh"))
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try AgentInstaller.target(for: b)) { XCTAssertTrue($0.localizedDescription.contains("VM is not running")) }
    }

    @MainActor
    func testLifecycleRequestsGoToTheOwnerAndSuspendRefusalsComeBack() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("life-\(UUID()).vitrinevm")
        var c = VMConfig(name: "life", guestOS: .linux, cpuCount: 1, memoryMiB: 2048)
        c.disks = [.init(path: "disk.img")]
        let b = try VMBundle.create(at: dir, config: c)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = try VirtualMachineController(bundle: b)
        var requested: [VMControl.Request.Op] = []
        controller.lifecycleRequestHandler = { requested.append($0) }
        for op in [VMControl.Request.Op.stop, .forceStop, .suspend] {
            let r = await controller.handleControl(.init(op: op))
            XCTAssertTrue(r.ok)
        }
        XCTAssertEqual(requested, [.stop, .forceStop, .suspend])
        controller.usbAttachments = [AttachedUSB(id: "usb1", attachment: .image(path: "/tmp/w.img", readOnly: false))]
        let refused = await controller.handleControl(.init(op: .suspend))
        XCTAssertFalse(refused.ok)
        XCTAssertEqual(refused.refused, true)
        XCTAssertTrue(refused.error?.contains("eject the USB drive") == true)
        XCTAssertEqual(requested.count, 3)
    }

    func testHostDeviceMatching() {
        let d = HostUSBDevice(vendorID: 0x0781, productID: 0x5581, locationID: 0x0210_0000, address: 3, registryID: 1)
        XCTAssertTrue(d.matches("0781:5581"))
        XCTAssertTrue(d.matches("0781:5581@02100000"))
        XCTAssertFalse(d.matches("0781:5582"))
        XCTAssertEqual(d.busNumber, 2)
        XCTAssertEqual(d.displayName, "USB device 0781:5581")
    }

    /// scripts/bench/display-probe.py writes and reads these keys itself.
    func testSampleWireFormat() throws {
        let request = try JSONDecoder().decode(VMControl.Request.self,
                                               from: Data(#"{"op":"sample","x":40,"y":41,"width":160,"height":161}"#.utf8))
        XCTAssertEqual(request, VMControl.Request(op: .sample, x: 40, y: 41, width: 160, height: 161))
        let reply = try JSONSerialization.jsonObject(with: JSONEncoder().encode(VMControl.Response(ok: true, color: [1, 2, 3]))) as? [String: Any]
        XCTAssertEqual(reply?["color"] as? [Double], [1, 2, 3])
    }

    func testAttachmentCodableRoundTrip() throws {
        let items: [USBAttachment] = [.image(path: "/x.img", readOnly: false),
                                      .host(HostUSBDevice(vendorID: 1, productID: 2, locationID: 3, address: 4, registryID: 5, name: "Key"))]
        XCTAssertEqual(try JSONDecoder().decode([USBAttachment].self, from: JSONEncoder().encode(items)), items)
    }
}
