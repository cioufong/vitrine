# Research notes (2026-10-12)

## Virtualization.framework by OS version
| Since | API | Used by Vitrine |
|---|---|---|
| 12 | `VZMacPlatformConfiguration`, `VZMacOSInstaller`, `VZMacOSRestoreImage`, virtiofs | ✓ |
| 13 | `VZMacTrackpadConfiguration`, `VZSpiceAgentPortAttachment` (clipboard), `macOSGuestAutomountTag`, Rosetta for Linux | ✓ |
| 14 | `saveMachineStateTo/restoreMachineStateFrom` (restored VM starts paused, disks not included), `VZMacKeyboardConfiguration`, `VZNVMExpressControllerDeviceConfiguration`, `automaticallyReconfiguresDisplay`, `VZMacGraphicsDisplay.reconfigure(sizeInPixels:)` | ✓ |
| 15 | Nested virt (M3+, Linux only), `VZXHCIControllerConfiguration` hot-plug, iCloud in macOS guests | – |
| 26 | `VZVmnetNetworkDeviceAttachment` (custom topologies, no entitlement for shared/host), ASIF disks, `VZVirtualMachine.queue` | ASIF ✓ |
| 27 | `VZMacGuestProvisioningOptions` (via `VZMacOSVirtualMachineStartOptions`), `VZCustomVirtioDevice*`, `VZUSBPassthroughDevice` (AccessoryAccess), EFI Secure Boot APIs, `DiskImageKit` (ASIF create + overlay layers) | provisioning ✓, ASIF ✓ |

Linux guests still only get 2D virtio-gpu scanout from VZ. Limit: 2 concurrent macOS guests (kernel-enforced).

## Prior art
| Project | License | Seamless windows | Notes |
|---|---|---|---|
| UTM | Apache-2.0 (bundles GPL QEMU) | no | VZ mode: no snapshots; QEMU: virgl/Venus via ANGLE/MoltenVK |
| VirtualBuddy | BSD-2 | no | macOS guests, guest app for clipboard |
| tart (openai/tart) | Fair Source (not OSI) | no | CI-focused CLI |
| GhostVM | no license | no | closest UX competitor |
| Lima / vfkit / Code-Hex/vz | Apache/MIT | no | Linux-focused |
| libkrun / krunkit | Apache-2.0 | no | Venus (Vulkan) GPU for Linux guests via MoltenVK |
| Cocoa-Way | GPL-3.0 | yes (Wayland rootless) | not a VM manager |

**Gap Vitrine fills:** seamless windows for macOS guests — nobody ships this, Parallels included
(Coherence is Windows-guest-only) — combined with one-click provisioning, clipboard, shared folders,
instant APFS snapshots and suspend/resume under an OSI license.

## User pain points
- Commercial tools: subscription pricing; seamless windows only for Windows guests.
- VZ-based tools: virtiofs needs a manual mount on Linux, clipboard only on macOS 15+ guests, and
  macOS limits the number of concurrent macOS VMs (2). UTM added snapshots in 5.0.6 (2026-09).

## Seamless windows approach (clean-room, public knowledge only)
Guest agent captures the guest display with ScreenCaptureKit (one stream, desktop + Dock excluded,
shadows off, clear background) and sends dirty rectangles plus a front-to-back window list over vsock.
The host keeps one IOSurface-backed framebuffer and shows one borderless NSWindow per guest window whose
layer displays the window's sub-rectangle (`contentsRect`). Input is mapped back to guest global
coordinates and injected with CGEvent. No Parallels code was inspected.

## Linux 3D (deferred, roadmap)
1. QEMU + virglrenderer/ANGLE (UTM-style build) — proven, GPL QEMU as external process.
2. libkrun/krunkit Venus — Vulkan compute today, display path unclear.
3. VZ `VZCustomVirtioDevice` virtio-gpu — blocked today (no config-write callback, no scanout object).

## Networking (2026-10-20)
vmnet facts found while building named and bridged networks — a network dies with the process that
created it, the subnet argument is the gateway address, the virtualization entitlement is required,
EBUSY in long-lived owners — and the per-network owner process (`vitrinectl netd`) that works around
the first are written up in [networking.md](networking.md#known-limitations-and-recommendations).

## Camera and Bluetooth
Neither is a macOS 27 regression: no Virtualization.framework release has had a camera or Bluetooth
device, and QEMU on macOS has no way to hand the Mac's Bluetooth controller (or built-in camera) to a
guest — there is no HCI passthrough and the controller isn't a USB device a VM could claim. What
remains possible:
- **Camera**: an external USB webcam through USB passthrough (QEMU); or capture the Mac's camera
  with AVFoundation on the host and feed frames to the guest agent, which exposes them as a virtual
  camera. Done for Linux guests (v4l2loopback, see [camera.md](camera.md)); macOS guests would need
  a signed CoreMediaIO extension and Windows guests a signed camera driver.
- **Bluetooth**: devices paired with the Mac already reach the guest as the Mac's keyboard, mouse
  and audio. A guest that needs its own Bluetooth stack (BLE development) could get a virtual HCI
  controller (Linux `hci_vhci` driven over the agent channel) whose traffic the host maps onto
  CoreBluetooth — feasible for BLE central/peripheral roles, not for Classic profiles, since
  CoreBluetooth exposes no raw HCI.
