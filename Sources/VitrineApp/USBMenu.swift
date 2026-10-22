import SwiftUI
import VitrineCore
import VitrineVZ

/// USB devices of the Mac (check = attached to this VM), disk images attached as USB drives, and
/// "Attach Disk Image…". Used in the Devices menu and the VM window toolbar.
struct USBMenuItems: View {
    @EnvironmentObject var model: AppModel
    let bundle: VMBundle
    @ObservedObject var controller: VirtualMachineController

    var body: some View {
        let running = controller.state == .running || controller.state == .paused
        let attached = controller.usbAttachments
        let hostDevices = HostUSB.devices()
        Section("USB Devices of This Mac") {
            if hostDevices.isEmpty { Text("No USB devices connected") }
            ForEach(hostDevices) { d in
                let item = attached.first { $0.attachment == .host(d) }
                Toggle(d.displayName, isOn: Binding(
                    get: { item != nil },
                    set: { on in
                        if on { model.attachUSB(bundle, .host(d)) } else if let item { model.detachUSB(bundle, id: item.id) }
                    }))
                .disabled(!running)
            }
        }
        Section("USB Drives") {
            ForEach(attached.filter { if case .image = $0.attachment { return true } else { return false } }) { a in
                Button("Eject \(a.attachment.localizedLabel)") { model.detachUSB(bundle, id: a.id) }
            }
            Button("Attach Disk Image as USB Drive…") { model.attachUSBImage(bundle) }
                .disabled(!running)
        }
    }
}
