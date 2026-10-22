// swift-tools-version: 6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Vitrine",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VitrineCore", targets: ["VitrineCore"]),
        .library(name: "VitrineAgentProtocol", targets: ["VitrineAgentProtocol"]),
        .executable(name: "vitrinectl", targets: ["vitrinectl"]),
        .executable(name: "VitrineApp", targets: ["VitrineApp"]),
        .executable(name: "VitrineAppProxy", targets: ["VitrineAppProxy"]),
        .executable(name: "vitrine-bridged", targets: ["vitrine-bridged"]),
    ],
    targets: [
        // Pure model layer: configs, bundles, disks, snapshots. No Virtualization.framework.
        .target(name: "VitrineCore", swiftSettings: v5),
        // Wire protocol shared by host and guest agent. Foundation only, so the guest can reuse it.
        .target(name: "VitrineAgentProtocol", swiftSettings: v5),
        // vmnet interfaces and Ethernet-frame sockets, shared by the backends and the bridge helper.
        .target(name: "VitrineNet", swiftSettings: v5),
        // Virtualization.framework backend.
        .target(name: "VitrineVZ", dependencies: ["VitrineCore", "VitrineAgentHost", "VitrineQEMU", "VitrineNet"], swiftSettings: v5),
        // QEMU child-process backend (Windows, x86_64 emulation). QEMU itself is never linked.
        .target(name: "VitrineQEMU", dependencies: ["VitrineCore", "VitrineAgentHost"], swiftSettings: v5),
        // Host side of the guest agent: connection, clipboard bridge, Coherence model.
        .target(name: "VitrineAgentHost", dependencies: ["VitrineCore", "VitrineAgentProtocol"], swiftSettings: v5),
        .executableTarget(name: "vitrinectl",
                          dependencies: ["VitrineCore", "VitrineVZ", "VitrineQEMU", "VitrineAgentHost", "VitrineNet"],
                          swiftSettings: v5),
        // UI strings: Resources/Localizable.xcstrings (see CONTRIBUTING.md, "Translations").
        .executableTarget(name: "VitrineApp",
                          dependencies: ["VitrineCore", "VitrineVZ", "VitrineQEMU", "VitrineAgentHost", "VitrineNet"],
                          resources: [.process("Resources")],
                          swiftSettings: v5),
        // Root LaunchDaemon serving bridged networking to the installing user's VMs (bundled in Vitrine.app).
        .executableTarget(name: "vitrine-bridged", dependencies: ["VitrineNet", "VitrineCore"], swiftSettings: v5),
        // Stand-in app for a guest app in the Mac Dock / ~/Applications (bundled in Vitrine.app).
        .executableTarget(name: "VitrineAppProxy", dependencies: ["VitrineCore"], swiftSettings: v5),
        // Guest agent (runs inside the macOS VM).
        .executableTarget(name: "vitrine-agent", dependencies: ["VitrineAgentProtocol"],
                          path: "guest/macos-agent/Sources", swiftSettings: v5),
        // "Vitrine Camera" CoreMediaIO extension for macOS guests (a system extension inside VitrineAgent.app).
        .executableTarget(name: "vitrine-camera-extension", path: "guest/macos-camera-extension/Sources", swiftSettings: v5),
        .testTarget(name: "VitrineCoreTests", dependencies: ["VitrineCore"], swiftSettings: v5),
        .testTarget(name: "VitrineVZTests", dependencies: ["VitrineVZ", "VitrineCore", "VitrineNet"], swiftSettings: v5),
        .testTarget(name: "VitrineQEMUTests", dependencies: ["VitrineQEMU", "VitrineCore"], swiftSettings: v5),
        .testTarget(name: "VitrineAgentHostTests",
                    dependencies: ["VitrineAgentHost", "VitrineAgentProtocol", "VitrineCore"], swiftSettings: v5),
        // Test the CLI's agent probe and the macOS guest agent's input injector in place
        // (`@testable import vitrinectl` / `vitrine_agent`).
        .testTarget(name: "AgentProbeRegression",
                    dependencies: ["vitrinectl", "VitrineQEMU", "VitrineAgentHost", "VitrineAgentProtocol", "VitrineCore"],
                    swiftSettings: v5),
        .testTarget(name: "MacInputInjectorRegression", dependencies: ["vitrine-agent", "VitrineAgentProtocol"],
                    swiftSettings: v5),
    ]
)
