import Foundation
import Virtualization
import VitrineCore
import VitrineQEMU

/// USB drives and passthrough devices, and the per-VM control socket that exposes them.
extension VirtualMachineController {
    // MARK: Lifecycle hooks

    /// Runs once a VM is up (both backends): opens the control socket and plugs back in whatever
    /// was attached when the VM was suspended.
    func didStartCommon() {
        extendGuestPartitionIfNeeded()
        pruneTransfers()
        // QEMU's user networking forwards ports itself (hostfwd).
        if config.network.isConnected, !config.network.portForwards.isEmpty, qemu == nil || networkLink?.qemuNetdev != nil {
            let snapshot = config, log = self.log, bundle = self.bundle
            let forwarder = PortForwarder(guestAddress: { bundle.guestIPAddress(snapshot) }, log: { log.write($0) })
            forwarder.start(config.network.portForwards)
            portForwarder = forwarder
        }
        do {
            controlServer = try VMControlServer(bundle: bundle) { [weak self] request in
                guard let self else { return VMControl.Response(ok: false, error: "VM is gone") }
                return await self.handleControl(request)
            }
        } catch {
            log.write("control socket unavailable: \(error.localizedDescription)")
        }
        if let data = try? Data(contentsOf: bundle.suspendedUSBURL),
           let saved = try? JSONDecoder().decode([USBAttachment].self, from: data) {
            try? FileManager.default.removeItem(at: bundle.suspendedUSBURL)
            Task { await replugUSB(saved) }
        }
    }

    /// Forgets runtime-only state when the VM stops (the devices went with it).
    func tearDownRuntime() {
        runGeneration += 1
        controlServer?.stop()
        controlServer = nil
        SerialConsoleBridge.stop(bundle: bundle)
        portForwarder?.stop()
        portForwarder = nil
        networkLink?.close()
        networkLink = nil
        bundle.recordGuestIP(nil)
        automationSink?.close()
        automationSink = nil
        usbAttachments = []
    }

    func handleControl(_ request: VMControl.Request) async -> VMControl.Response {
        switch request.op {
        case .ping:
            return VMControl.Response(ok: true)
        case .portAdd, .portRemove:
            guard bundle.holdsRunLock, state == .running || state == .paused else {
                return VMControl.Response(ok: false, error: "VM is not running")
            }
            do {
                if request.op == .portAdd {
                    guard let forward = request.portForward else { throw VitrineError.invalidConfig("no port forward") }
                    try updatePortForwards {
                        $0.removeAll { $0.hostPort == forward.hostPort && $0.proto == forward.proto }
                        $0.append(forward)
                    }
                } else {
                    guard let port = request.hostPort else { throw VitrineError.invalidConfig("no host port") }
                    try updatePortForwards { $0.removeAll { $0.hostPort == port } }
                }
                return VMControl.Response(ok: true)
            } catch {
                return .failure(error)
            }
        case .stop, .forceStop:
            performLifecycleRequest(request.op)
            return VMControl.Response(ok: true)
        case .suspend:
            do { try checkUSBAllowsSuspend() } catch {
                return VMControl.Response(ok: false, error: error.localizedDescription, refused: true)
            }
            performLifecycleRequest(.suspend)
            return VMControl.Response(ok: true)
        case .dropFiles:
            let urls = (request.paths ?? []).map { URL(fileURLWithPath: $0) }
            guard !urls.isEmpty else { return VMControl.Response(ok: false, error: "no files") }
            do {
                try sendFiles(urls)
                return VMControl.Response(ok: true)
            } catch {
                return .failure(error)
            }
        case .reloadShares:
            do {
                try updateShares(try bundle.loadConfig().shares)
                return VMControl.Response(ok: true)
            } catch {
                return .failure(error)
            }
        case .screenshot, .keys, .pointer, .sample:
            do {
                return try await handleAutomation(request)
            } catch {
                return .failure(error)
            }
        case .text:
            do {
                return try await handleAgentText(request)
            } catch {
                return .failure(error)
            }
        case .requestPermissions:
            guard config.guestOS == .macOS else {
                return VMControl.Response(ok: false, error: "only macOS guests ask for these permissions")
            }
            guard agent?.guestHello != nil else {
                return VMControl.Response(ok: false, error: "\(bundle.name)'s guest agent isn't connected (it runs once a user is logged in)")
            }
            // ok with a note: nothing to ask for.
            guard agentLacksPermissions else {
                return VMControl.Response(ok: true, error: "Vitrine Agent already has Screen Recording and Accessibility")
            }
            guard requestAgentPermissions() else {
                return VMControl.Response(ok: false, error: "the agent in \(bundle.name) is too old to ask; update it with `vitrinectl agent install \(bundle.name)`")
            }
            return VMControl.Response(ok: true)
        case .usbList:
            return VMControl.Response(ok: true, usb: usbAttachments)
        case .usbAttach:
            guard let attachment = request.attachment else { return VMControl.Response(ok: false, error: "nothing to attach") }
            do {
                let (attached, warning) = try await attachUSB(attachment)
                return VMControl.Response(ok: true, error: warning, usb: usbAttachments, attached: attached)
            } catch {
                return .failure(error)
            }
        case .usbDetach:
            guard let id = request.id else { return VMControl.Response(ok: false, error: "which device?") }
            do {
                try await detachUSB(id: id)
                return VMControl.Response(ok: true, usb: usbAttachments)
            } catch {
                return .failure(error)
            }
        }
    }

    /// Starts a requested stop/suspend/forceStop without waiting for it: the reply would race the
    /// owner closing the socket (or exiting) once the VM is down.
    private func performLifecycleRequest(_ op: VMControl.Request.Op) {
        if let lifecycleRequestHandler { return lifecycleRequestHandler(op) }
        Task {
            switch op {
            case .suspend: try? await suspend() // failures end up in lastError
            case .forceStop: await forceStop()
            default: await stop()
            }
        }
    }

    // MARK: USB

    /// Plugs a disk image (as a USB flash drive) or a Mac USB device into the running VM. Returns the
    /// attachment and, for passthrough devices, any warning the backend reported.
    @discardableResult
    public func attachUSB(_ attachment: USBAttachment) async throws -> (AttachedUSB, String?) {
        guard state == .running || state == .paused else { throw VitrineError.invalidConfig("\(bundle.name) isn't running") }
        var attachment = attachment
        if case .image(let path, readOnly: false) = attachment, DiskImage.isUDIF(URL(fileURLWithPath: path)) {
            attachment = .image(path: path, readOnly: true) // .dmg images are a read-only format
        }
        switch attachment {
        case .host(let d):
            if usbAttachments.contains(where: { $0.attachment == attachment }) {
                throw VitrineError.invalidConfig("\(d.displayName) is already attached")
            }
        case .image(let path, _):
            // The same image twice (or the VM's own disk) would be written through two devices.
            let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            let inUse = usbAttachments.contains {
                if case .image(let p, _) = $0.attachment { return URL(fileURLWithPath: p).resolvingSymlinksInPath().path == target }
                return false
            } || config.disks.contains { bundle.resolve($0.path).resolvingSymlinksInPath().path == target }
            if inUse { throw VitrineError.invalidConfig("\((path as NSString).lastPathComponent) is already in use by this VM") }
        }
        let id = "usb\(nextUSBNumber)"
        nextUSBNumber += 1
        guard let b = backend else { throw VitrineError.invalidConfig("\(bundle.name) isn't running") }
        let generation = runGeneration
        let warning = try await b.attachUSB(attachment, id: id)
        // Stopped or suspending meanwhile: the device went with the old run (or is about to).
        if runGeneration != generation || backend !== b || !(state == .running || state == .paused) {
            if backend === b {
                if b is QEMUMachine {
                    try? await b.detachUSB(attachment, id: id)
                } else {
                    // Still plugged into a live machine (e.g. one that is about to be saved): take it out.
                    do { try await b.detachUSB(attachment, id: id) } catch {
                        // Couldn't: keep tracking it, so it can be ejected later and blocks saving.
                        usbAttachments.append(AttachedUSB(id: id, attachment: attachment))
                        log.write("USB \(id) \(attachment.label) attached while the VM was changing state; still attached")
                        throw error
                    }
                }
            }
            throw VitrineError.invalidConfig("\(bundle.name) stopped while \(attachment.label) was being attached")
        }
        let attached = AttachedUSB(id: id, attachment: attachment)
        usbAttachments.append(attached)
        log.write("USB attached: \(id) \(attachment.label)" + (warning.map { " — \($0)" } ?? ""))
        return (attached, warning)
    }

    public func detachUSB(id: String) async throws {
        guard let item = usbAttachments.first(where: { $0.id == id }) else {
            throw VitrineError.invalidConfig("no USB attachment \(id)")
        }
        try await backend?.detachUSB(item.attachment, id: id)
        usbAttachments.removeAll { $0.id == id }
        log.write("USB detached: \(id) \(item.attachment.label)")
    }

    /// Why the VM can't be suspended right now (an attached drive), or nil.
    public var suspendBlocker: String? {
        do { try checkUSBAllowsSuspend(); return nil } catch { return error.localizedDescription }
    }

    /// Suspending unplugs USB drives without the guest's cooperation, so a writable drive could lose
    /// data the guest hasn't written yet: those have to be ejected first.
    func checkUSBAllowsSuspend() throws {
        for item in usbAttachments {
            switch item.attachment {
            case .image(_, readOnly: false):
                throw VitrineError.invalidConfig("eject the USB drive \(item.attachment.label) in the guest and detach it before suspending (the guest may still have unwritten data on it)")
            case .host(let d) where d.isStorage != false:
                // Physical drives too; a device whose class wasn't recorded counts as one.
                throw VitrineError.invalidConfig("eject \(d.displayName) in the guest and disconnect it before suspending (the guest may still have unwritten data on it)")
            default:
                break
            }
        }
    }

    /// A device couldn't be unplugged before suspending; `unplugged` were, and go back in once the
    /// VM is running again.
    struct USBUnplugError: LocalizedError {
        let unplugged: [USBAttachment]
        let underlying: Error
        var errorDescription: String? { underlying.localizedDescription }
    }

    /// Unplugs everything before a suspend (hot-plugged devices can't be saved with the machine). If
    /// one can't be unplugged the suspend must not go ahead (the saved state would include a device
    /// the resumed machine doesn't have): throws USBUnplugError.
    func unplugAllUSB() async throws -> [USBAttachment] {
        var done: [USBAttachment] = []
        for item in usbAttachments {
            do {
                try await detachUSB(id: item.id)
                done.append(item.attachment)
            } catch {
                log.write("could not unplug \(item.attachment.label) before suspending: \(error.localizedDescription)")
                throw USBUnplugError(unplugged: done, underlying: error)
            }
        }
        return done
    }

    func saveSuspendedUSB(_ attachments: [USBAttachment]) throws {
        if attachments.isEmpty {
            try? FileManager.default.removeItem(at: bundle.suspendedUSBURL)
        } else {
            try JSONEncoder().encode(attachments).write(to: bundle.suspendedUSBURL, options: .atomic)
        }
    }

    func replugUSB(_ attachments: [USBAttachment]) async {
        for var a in attachments {
            if case .host(let d) = a {
                // Re-plugged while suspended, the device may have a new bus address: use the current one.
                guard let current = HostUSB.current(matching: d) else {
                    log.write("not re-attaching \(d.displayName): no longer plugged in")
                    continue
                }
                a = .host(current)
            }
            do { try await attachUSB(a) } catch {
                log.write("could not re-attach \(a.label): \(error.localizedDescription)")
            }
        }
    }
}
