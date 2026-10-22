import SwiftUI
import VitrineCore
import VitrineVZ

/// Configuration ▸ Network: what the VM's adapter is plugged into.
struct NetworkAdapterSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var controller: VirtualMachineController
    @State private var networks = VirtualNetworks.load()
    @State private var interfaces = BridgeInterfaces.list()
    @State private var fixedIP = ""
    @State private var helperBusy = false

    /// One Picker tag per choice: the mode plus, for named and bridged, which one.
    enum Source: Hashable {
        case nat, hostOnly, none
        case network(String)
        case bridged(String)
    }

    private var config: VMConfig { controller.config }

    private var source: Source {
        switch config.network.mode {
        case .nat: return .nat
        case .hostOnly: return .hostOnly
        case .none: return .none
        case .network: return .network(config.network.networkName ?? "")
        case .bridged: return .bridged(config.network.bridgeInterface ?? "")
        }
    }

    var body: some View {
        Section("Network adapter") {
            Picker("Source", selection: Binding(get: { source }, set: apply)) {
                Text("Shared Network (NAT)").tag(Source.nat)
                Text("Host-Only (no internet)").tag(Source.hostOnly)
                if !networks.isEmpty {
                    Divider()
                    ForEach(networks) { n in
                        Text("Network: \(n.name)").tag(Source.network(n.name))
                    }
                }
                if case .network(let name) = source, !networks.contains(where: { $0.name == name }) {
                    Text("Network: \(name) (missing)").tag(source)
                }
                Divider()
                ForEach(interfaces) { i in
                    Text("Bridged: \(i.displayName) (\(i.bsdName))").tag(Source.bridged(i.bsdName))
                }
                if case .bridged(let name) = source, !interfaces.contains(where: { $0.bsdName == name }) {
                    Text("Bridged: \(name) (not available)").tag(source)
                }
                Divider()
                Text("Disconnected").tag(Source.none)
            }
            caption
            LabeledContent("MAC address", value: config.network.macAddress).textSelection(.enabled)
            if let ip = controller.bundle.guestIPAddress(config) {
                LabeledContent("IP address", value: ip).textSelection(.enabled)
            }
        }
        .onAppear {
            networks = VirtualNetworks.load()
            interfaces = BridgeInterfaces.list()
            fixedIP = config.network.fixedIPv4 ?? ""
        }
        if case .network(let name) = source, let net = networks.first(where: { $0.name == name }), net.dhcp {
            Section("Address") {
                LabeledContent("Fixed IP address") {
                    TextField("Automatic (DHCP)", text: $fixedIP, prompt: Text("Automatic (DHCP)"))
                        .labelsHidden().multilineTextAlignment(.trailing)
                        .onSubmit(saveFixedIP)
                }
                Text(net.subnet.map { String(localized: "Reserved for this VM by the network's DHCP server; pick an address in \($0) other than \(IPv4Subnet(cidr: $0)?.hostAddress ?? "") (the Mac).") }
                     ?? String(localized: "Give the network a subnet in Settings ▸ Networks to reserve fixed addresses."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var caption: some View {
        switch source {
        case .hostOnly:
            note(config.effectiveBackend == .vz
                 ? "The VM reaches this Mac and other host-only VMs, but not the internet. Needs macOS 26 or later."
                 : "The VM can't open connections to the Mac or the internet; forwarded ports and shared folders still work.")
        case .network(let name):
            let net = networks.first { $0.name == name }
            note(net == nil
                 ? "This network no longer exists. Choose another one or create it in Settings ▸ Networks."
                 : net!.kind == .shared
                 ? "The VM reaches the other VMs on “\(name)”, this Mac and the internet. Needs macOS 26 or later."
                 : "The VM reaches the other VMs on “\(name)” and this Mac, but not the internet. Needs macOS 26 or later.")
            windowsSharesNote
        case .bridged(let name):
            if Entitlement.vmNetworking.isGranted || BridgeSockets.socket(for: name) != nil {
                note("The VM joins the network \(name) is on and gets its own address from that network's router, like another computer.")
            } else {
                note("Bridging needs Vitrine's bridge helper, which asks for an administrator's password once.")
                HStack {
                    Button("Install Bridge Helper…", action: installHelper).disabled(helperBusy)
                    if helperBusy { ProgressView().controlSize(.small) }
                }
            }
            windowsSharesNote
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var windowsSharesNote: some View {
        if config.guestOS == .windows {
            note("Shared folders and drag and drop for Windows need the Shared Network (NAT).")
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func apply(_ s: Source) {
        var c = config
        switch s {
        case .nat: c.network.mode = .nat
        case .hostOnly: c.network.mode = .hostOnly
        case .none: c.network.mode = .none
        case .network(let name): c.network.mode = .network; c.network.networkName = name
        case .bridged(let name): c.network.mode = .bridged; c.network.bridgeInterface = name
        }
        do { try controller.saveConfig(c) } catch { model.report(error) }
    }

    private func saveFixedIP() {
        var c = config
        let t = fixedIP.trimmingCharacters(in: .whitespaces)
        c.network.fixedIPv4 = t.isEmpty ? nil : t
        if let ip = c.network.fixedIPv4, let cidr = networks.first(where: { $0.name == c.network.networkName })?.subnet,
           let subnet = IPv4Subnet(cidr: cidr), !(subnet.contains(ip) && IPv4Subnet.parse(ip).map(subnet.assignableRange.contains) == true) {
            model.report(VitrineError.invalidConfig("\(ip) is not a free address in \(cidr)"))
            fixedIP = config.network.fixedIPv4 ?? ""
            return
        }
        do { try controller.saveConfig(c) } catch {
            model.report(error)
            fixedIP = config.network.fixedIPv4 ?? ""
        }
    }

    private func installHelper() {
        helperBusy = true
        Task.detached {
            let failure: Error?
            do { try BridgeHelper.install(); failure = nil } catch { failure = error }
            await MainActor.run {
                helperBusy = false
                if let failure, failure.localizedDescription != "cancelled" { model.report(failure) }
                interfaces = BridgeInterfaces.list()
            }
        }
    }
}
