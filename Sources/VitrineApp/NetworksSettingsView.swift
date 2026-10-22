import SwiftUI
import SystemConfiguration
import VitrineCore
import VitrineNet
import VitrineVZ

/// Settings ▸ Networks: the library's named networks, and the helper bridged networking needs.
struct NetworksSettingsView: View {
    @State private var networks = VirtualNetworks.load()
    @State private var selection: String?
    @State private var newName = ""
    @State private var error: String?
    @State private var helperInstalled = BridgeHelper.isInstalled
    @State private var helperBusy = false

    var body: some View {
        Form {
            Section {
                ForEach(networks) { n in
                    NetworkRow(network: n, users: users(of: n.name), save: { replace(n.name, with: $0) },
                               delete: { delete(n.name) })
                }
                HStack {
                    TextField("New network name", text: $newName, prompt: Text("New network name")).labelsHidden()
                        .onSubmit(add)
                    Button("Add", action: add).disabled(!VirtualNetwork.isValidName(newName))
                }
            } header: {
                Text("Named networks")
            } footer: {
                Text("VMs on the same named network reach each other and this Mac, whether they run in Vitrine or in vitrinectl. Choose a network for a VM under Configuration ▸ Network. Changes apply once every VM on the network has stopped. Needs macOS 26 or later.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Section {
                LabeledContent("Bridge helper") {
                    Text(helperInstalled ? "Installed" : "Not installed")
                }
                HStack {
                    if helperInstalled {
                        Button("Uninstall Bridge Helper…") { runHelper(install: false) }
                    } else {
                        Button("Install Bridge Helper…") { runHelper(install: true) }
                    }
                    if helperBusy { ProgressView().controlSize(.small) }
                }
                .disabled(helperBusy)
            } header: {
                Text("Bridged networking")
            } footer: {
                Text("A bridged VM joins the same network as one of the Mac's interfaces and gets its own address from that network's router. macOS lets only administrators bridge, so a small helper runs in the background for your account; installing it asks for an administrator's password. socket_vmnet, if you already run it in bridged mode, works too.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }

    private func users(of name: String) -> [String] {
        VMLibrary.list().compactMap { b -> String? in
            guard let c = try? b.loadConfig(), c.network.mode == .network, c.network.networkName == name else { return nil }
            return c.name
        }
    }

    private func commit(_ list: [VirtualNetwork]) -> Bool {
        do {
            try VirtualNetworks.save(list)
            networks = list
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func add() {
        guard VirtualNetwork.isValidName(newName) else { return }
        if commit(networks + [VirtualNetwork(name: newName)]) { newName = "" }
    }

    private func replace(_ name: String, with n: VirtualNetwork) {
        var list = networks
        guard let i = list.firstIndex(where: { $0.name == name }) else { return }
        list[i] = n
        _ = commit(list)
    }

    private func delete(_ name: String) {
        let using = users(of: name)
        guard using.isEmpty else {
            error = String(localized: "\(using.joined(separator: ", ")) still use “\(name)”. Move them to another network first.")
            return
        }
        _ = commit(networks.filter { $0.name != name })
    }

    private func runHelper(install: Bool) {
        helperBusy = true
        Task.detached {
            let result: String?
            do {
                if install { try BridgeHelper.install() } else { try BridgeHelper.uninstall() }
                result = nil
            } catch {
                result = error.localizedDescription == "cancelled" ? nil : error.localizedDescription
            }
            await MainActor.run {
                helperBusy = false
                helperInstalled = BridgeHelper.isInstalled
                error = result
            }
        }
    }
}

private struct NetworkRow: View {
    let network: VirtualNetwork
    let users: [String]
    let save: (VirtualNetwork) -> Void
    let delete: () -> Void
    @State private var subnet = ""
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Picker("Kind", selection: Binding(get: { network.kind }, set: { var n = network; n.kind = $0; save(n) })) {
                Text("Shared (internet through the Mac)").tag(VirtualNetwork.Kind.shared)
                Text("Host-only (no internet)").tag(VirtualNetwork.Kind.hostOnly)
            }
            LabeledContent("Subnet") {
                TextField("Automatic", text: $subnet, prompt: Text(VmnetNetworks.activeSubnet(networkName: network.name).map { String(localized: "Automatic (now \($0))") } ?? String(localized: "Automatic")))
                    .labelsHidden().multilineTextAlignment(.trailing)
                    .onSubmit {
                        var n = network
                        let t = subnet.trimmingCharacters(in: .whitespaces)
                        n.subnet = t.isEmpty ? nil : t
                        save(n)
                    }
            }
            Toggle("Hand out addresses (DHCP)", isOn: Binding(get: { network.dhcp }, set: { var n = network; n.dhcp = $0; save(n) }))
            HStack {
                Text(users.isEmpty ? String(localized: "No VMs use this network.") : String(localized: "Used by \(users.joined(separator: ", "))"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Delete Network", role: .destructive, action: delete).disabled(!users.isEmpty)
            }
        } label: {
            HStack {
                Text(network.name)
                Spacer()
                Text(network.kind == .shared ? "Shared" : "Host-only").foregroundStyle(.secondary)
                Text(network.subnet ?? VmnetNetworks.activeSubnet(networkName: network.name) ?? String(localized: "Automatic"))
                    .font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .onAppear { subnet = network.subnet ?? "" }
        .onChange(of: network.subnet) { _, v in subnet = v ?? "" }
    }
}

/// Mac interfaces a VM can be bridged to, with their System Settings names ("Wi-Fi", "Ethernet").
enum BridgeInterfaces {
    struct Interface: Hashable, Identifiable {
        let bsdName: String
        let displayName: String
        var id: String { bsdName }
    }

    static func list() -> [Interface] {
        var names: [String: String] = [:]
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for i in all {
                if let bsd = SCNetworkInterfaceGetBSDName(i) as String?,
                   let display = SCNetworkInterfaceGetLocalizedDisplayName(i) as String? {
                    names[bsd] = display
                }
            }
        }
        return VmnetInterfaces.bridgeable().map { Interface(bsdName: $0, displayName: names[$0] ?? $0) }
    }
}
