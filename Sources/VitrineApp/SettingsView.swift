import ServiceManagement
import SwiftUI
import VitrineCore

/// Vitrine ▸ Settings… (app-wide preferences; per-VM settings live in each VM's Configuration).
struct SettingsView: View {
    @State private var keepAwake = VitrinePreferences.keepAwakeWhileRunning
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
            NetworksSettingsView()
                .frame(width: 560, height: 520)
                .tabItem { Label("Networks", systemImage: "network") }
        }
    }

    private var general: some View {
        Form {
            Section {
                Toggle("Keep the Mac awake while virtual machines are running", isOn: $keepAwake)
                    .onChange(of: keepAwake) { _, on in
                        VitrinePreferences.keepAwakeWhileRunning = on
                        SleepGuard.shared.preferenceChanged()
                    }
                Text("Stops idle sleep, which would freeze running guests and drop their network connections. The display can still sleep.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Open Vitrine at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in setOpenAtLogin(on) }
                Text("VMs set to “Start when Vitrine opens” in their Configuration start then too.")
                    .font(.caption).foregroundStyle(.secondary)
                if loginStatus == .requiresApproval {
                    Text("Allow Vitrine under System Settings ▸ General ▸ Login Items.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        loginStatus = SMAppService.mainApp.status
        openAtLogin = loginStatus == .enabled || loginStatus == .requiresApproval
    }
}
