import SwiftUI
import VitrineCore
import VitrineVZ

/// Configuration ▸ Network: ports on the Mac forwarded into the guest (applied at the next start).
struct PortForwardsEditor: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var controller: VirtualMachineController
    @State private var hostPort = ""
    @State private var guestPort = ""
    @State private var proto: VMConfig.PortForward.Proto = .tcp
    @State private var everyone = false

    var body: some View {
        Section("Port forwarding") {
            ForEach(controller.config.network.portForwards) { f in
                HStack {
                    Text("\(f.proto.rawValue.uppercased())  \(f.hostAddress):\(f.hostPort)  →  guest \(f.guestPort)")
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Button { update { $0.removeAll { $0 == f } } } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            HStack {
                Picker("", selection: $proto) {
                    ForEach(VMConfig.PortForward.Proto.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                }.labelsHidden().frame(width: 72)
                TextField("Mac port", text: $hostPort, prompt: Text("Mac port")).labelsHidden().frame(width: 90)
                Text("→")
                TextField("Guest port", text: $guestPort, prompt: Text("Guest port")).labelsHidden().frame(width: 90)
                Toggle("Reachable from the network", isOn: $everyone).toggleStyle(.checkbox).font(.caption)
                Button("Add", action: add).disabled(Int(hostPort) == nil || Int(guestPort) == nil)
            }
            Text("Forwards take effect the next time the VM starts. Leave “Reachable from the network” off to allow connections from this Mac only.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func add() {
        guard let h = Int(hostPort), let g = Int(guestPort) else { return }
        let f = VMConfig.PortForward(proto: proto,
                                     hostAddress: everyone ? "0.0.0.0" : "127.0.0.1", hostPort: h, guestPort: g)
        update { forwards in
            forwards.removeAll { $0.hostPort == f.hostPort && $0.proto == f.proto }
            forwards.append(f)
        }
        hostPort = ""; guestPort = ""
    }

    private func update(_ change: (inout [VMConfig.PortForward]) -> Void) {
        do { try controller.updatePortForwards(change) } catch { model.report(error) }
    }
}
