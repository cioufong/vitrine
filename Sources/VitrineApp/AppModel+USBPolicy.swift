import AppKit
import VitrineCore
import VitrineVZ

/// Newly plugged-in USB devices: connect them to the VM in front, ask, or leave them with the Mac
/// (Settings → Hardware → USB & Bluetooth), and drop devices that were unplugged from the Mac.
extension AppModel {
    private static let usbMonitor = HostUSBMonitor()

    /// Registered from applicationDidFinishLaunching.
    func startUSBMonitor() {
        let monitor = Self.usbMonitor
        monitor.onArrival = { [weak self] d in MainActor.assumeIsolated { self?.usbArrived(d) } }
        monitor.onRemoval = { [weak self] rid in MainActor.assumeIsolated { self?.usbRemoved(registryID: rid) } }
        monitor.start()
    }

    /// The running VM whose window (display or Coherence) is in front, if Vitrine is active.
    var frontVM: VirtualMachineController? {
        guard NSApp.isActive else { return nil }
        let key = NSApp.keyWindow ?? NSApp.mainWindow
        let path = displayWindows.first { $0.value === key }?.key
            ?? coherenceActive.first { coherenceController(for: VMBundle(url: URL(fileURLWithPath: $0)))?.owns(key) == true }
            ?? (coherenceActive.count == 1 ? coherenceActive.first : nil)
        guard let path, let c = controller(for: VMBundle(url: URL(fileURLWithPath: path))),
              c.state == .running || c.state == .paused else { return nil }
        return c
    }

    private static var arrivals: [HostUSBDevice] = []
    private static var handlingArrivals = false

    /// Called from the IOKit notification: queues the device and handles arrivals one at a time,
    /// outside the callback (a hub brings several at once, and the question is a modal alert).
    func usbArrived(_ device: HostUSBDevice) {
        guard device.isHub != true else { return }
        Self.arrivals.append(device)
        DispatchQueue.main.async { [weak self] in self?.handleArrivals() }
    }

    private func handleArrivals() {
        guard !Self.handlingArrivals else { return } // the running loop picks the new one up
        Self.handlingArrivals = true
        defer { Self.handlingArrivals = false }
        while !Self.arrivals.isEmpty { handleArrival(Self.arrivals.removeFirst()) }
    }

    private func handleArrival(_ device: HostUSBDevice) {
        let running = activeControllers.filter { $0.state == .running || $0.state == .paused }
        // The VM in front decides; otherwise a lone running VM set to connect automatically takes it.
        let target = frontVM ?? (running.count == 1 && running[0].config.features.usbConnect == .connect ? running[0] : nil)
        guard let target else { return }
        switch target.config.features.usbConnect {
        case .keepOnMac:
            return
        case .connect:
            target.note("USB: connecting new device \(device.displayName)")
            attachUSB(target.bundle, .host(device))
        case .ask:
            let alert = NSAlert()
            alert.messageText = String(localized: "Connect “\(device.displayName)” to \(target.bundle.name)?")
            alert.informativeText = String(localized: "The device was just plugged into this Mac. If you connect it to the virtual machine, the Mac can't use it until you disconnect it again (Devices → USB).")
            alert.addButton(withTitle: String(localized: "Connect to \(target.bundle.name)"))
            alert.addButton(withTitle: String(localized: "Keep on Mac"))
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = String(localized: "Always do this for \(target.bundle.name)")
            let connect = alert.runModal() == .alertFirstButtonReturn
            if alert.suppressionButton?.state == .on {
                var c = (try? target.bundle.loadConfig()) ?? target.config // may have changed while asking
                c.features.usbConnect = connect ? .connect : .keepOnMac
                do { try target.saveConfig(c) } catch { report(error) }
            }
            // Still there after the question? (It may have been unplugged while the alert was up.)
            if connect, let current = HostUSB.current(matching: device) {
                attachUSB(target.bundle, .host(current))
            }
        }
    }

    /// A device left the Mac: forget it in any VM it was connected to.
    func usbRemoved(registryID: UInt64) {
        for c in activeControllers {
            for a in c.usbAttachments {
                guard case .host(let d) = a.attachment, d.registryID == registryID else { continue }
                c.note("USB: \(d.displayName) was unplugged from the Mac")
                Task { try? await c.detachUSB(id: a.id) }
            }
        }
    }
}
