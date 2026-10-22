# Signing Vitrine yourself

Vitrine is open source and has no paid Apple Developer account behind its builds. The build
scripts therefore sign everything **ad-hoc** by default, which needs no account and covers almost
everything. A few features depend on entitlements that Apple grants only to a developer team. The
code for those features is all there. To turn them on, sign your own build with your own team.

| Feature | Ad-hoc build | Needs |
|---------|--------------|-------|
| VMs (Virtualization.framework, QEMU), shared folders, agents, Coherence, NAT/host-only networks | ✓ | — |
| Mac camera and microphone in guests | ✓ (Vitrine asks for permission) | — |
| Bridged networking | ✓ through the `vitrine-bridged` helper (installed once with your admin password) | — |
| Bridged networking without the helper (VZ's own bridge) | — | `com.apple.vm.networking` |
| USB device passthrough on Virtualization.framework VMs | — | `com.apple.developer.accessory-access.usb` |
| **Vitrine Camera** in macOS guests | — | the macOS agent signed by a team, with `com.apple.developer.system-extension.install` |

Vitrine checks its own entitlements when it runs (`Sources/VitrineCore/Entitlements.swift`). If
it has `com.apple.vm.networking`, bridged VMs use VZ's built-in bridge and the network settings
stop offering the helper. If it doesn't, nothing changes.

## Environment variables

`scripts/build-app.sh`, `scripts/build-cli.sh` and `scripts/build-agent.sh` read these (see
`scripts/lib/signing.sh`):

| Variable | Meaning |
|----------|---------|
| `VITRINE_SIGN_IDENTITY` | `-` (ad-hoc, the default), or a code-signing identity from your keychain: `Apple Development: …`, `Developer ID Application: …`, or the name of a self-signed code-signing certificate. Any real identity turns on the hardened runtime, and the scripts add the camera and microphone entitlements it then requires. Developer ID signatures also get a secure timestamp. |
| `VITRINE_BUNDLE_ID` | Vitrine.app's bundle identifier (default `io.github.cioufong.vitrine.app`). Explicit App IDs are unique across all Apple teams, so use your own, e.g. `com.example.vitrine`. |
| `VITRINE_PROVISIONING_PROFILE` | A `.provisionprofile` for that App ID that grants the restricted entitlements below. It is embedded in Vitrine.app, and the scripts read its Team ID. |
| `VITRINE_ENTITLEMENTS` | Restricted entitlements for Vitrine.app, comma-separated: `bridged` (`com.apple.vm.networking`), `usb` (`com.apple.developer.accessory-access.usb`). |
| `VITRINE_AGENT_SIGN_IDENTITY` | Identity for the macOS guest agent and its camera extension (defaults to `VITRINE_SIGN_IDENTITY`). |
| `VITRINE_AGENT_BUNDLE_ID` | The agent's bundle identifier (default `io.github.cioufong.vitrine.agent`). The camera extension is `<this>.camera`. |
| `VITRINE_AGENT_PROVISIONING_PROFILE` | Profile for the agent's App ID with the System Extension capability (`com.apple.developer.system-extension.install`). |
| `VITRINE_AGENT_EXTENSION_PROFILE` | Profile for the camera extension, if your team setup needs one. |
| `VITRINE_AGENT_TEAM_ID` | Your Team ID, when no agent profile provides it. |
| `VITRINE_ADHOC_STABLE_REQUIREMENT` | `1` keeps privacy permissions of ad-hoc builds across rebuilds (see [below](#privacy-permissions-across-rebuilds)). For development Macs only. |

Settings that belong to one Mac rather than to the project, such as your signing identity or
`VITRINE_ADHOC_STABLE_REQUIREMENT=1`, can go in `signing.local.sh` at the root of your checkout.
The build scripts source it if it exists (it is a shell file of `VAR=value` lines), and git ignores
it.

Example, a Developer ID build with VZ bridging and the guest camera:

```sh
export VITRINE_SIGN_IDENTITY="Developer ID Application: Jane Doe (ABCDE12345)"
export VITRINE_BUNDLE_ID=com.example.vitrine
export VITRINE_PROVISIONING_PROFILE=~/Profiles/Vitrine_DeveloperID.provisionprofile
export VITRINE_ENTITLEMENTS=bridged
export VITRINE_AGENT_BUNDLE_ID=com.example.vitrine.agent
export VITRINE_AGENT_PROVISIONING_PROFILE=~/Profiles/VitrineAgent_DeveloperID.provisionprofile
./scripts/build-app.sh release
```

`scripts/tests/signing-test.sh` checks which entitlements each setup produces, using ad-hoc signing
only. No account is needed to run it.

## Getting the entitlements

1. In your Apple Developer account, register explicit App IDs for Vitrine.app and for the agent
   (and for `<agent>.camera` if you want it to have its own profile).
2. **Bridged networking** (`com.apple.vm.networking`) and **USB** are *managed* entitlements:
   request them from Apple for your team first. Once Apple approves, enable them on the App ID.
   **System Extension** is a normal capability for the agent's App ID.
3. Create a provisioning profile for each App ID: *Developer ID* to share builds with others, or
   *macOS App Development* for your own Macs, which must be registered in your account.
4. Point the variables above at the profiles and build.

To give your build to other people, notarize it as well (`xcrun notarytool submit … --wait`, then
`xcrun stapler staple dist/Vitrine.app`).

### Limits

- **Helper tools can't carry provisioning profiles.** `vitrinectl`, `vitrine-bridged` and
  `VitrineAppProxy` are bare executables. They keep the unrestricted entitlements, so
  `vitrinectl`-only (headless) VMs bridge through the helper even in a signed build.
- **Restricted entitlements without a profile.** macOS kills a program at launch when it claims
  restricted entitlements that no profile backs. The scripts warn when you ask for that. The only
  way around it is to relax AMFI (Apple Mobile File Integrity) checks, which needs SIP partly off
  and weakens the security of the whole Mac. Do that only on a Mac set aside for testing, never on
  a Mac you use every day. Vitrine never asks for it.

## Privacy permissions across rebuilds

macOS keys privacy grants (Camera, Microphone, Screen Recording, Accessibility) to a program's
*designated requirement*. An ad-hoc signature pins the exact binary, so after every rebuild of
Vitrine.app or the guest agent macOS asks again. Builds signed with a real identity (including a
self-signed code-signing certificate) have a requirement that names that certificate or your team
instead, which stays stable across rebuilds.

On a development Mac, `VITRINE_ADHOC_STABLE_REQUIREMENT=1` gives ad-hoc bundles (Vitrine.app, the
agent and its camera extension) a designated requirement of just their bundle identifier, so
grants survive rebuilds. The catch: anyone can sign code ad-hoc with that identifier, so any program
that replaces your Vitrine.app (or the agent in a guest) inherits its camera, microphone and other
grants. Don't use it for builds you give to other people.

## The macOS guest camera

Apps in a macOS guest see the Mac's camera through a CoreMediaIO camera extension, *Vitrine
Camera*, which ships inside `VitrineAgent.app` (`Contents/Library/SystemExtensions/`, source in
`guest/macos-camera-extension`). Before macOS activates a system extension:

- the app containing it must be in `/Applications` of the guest (Vitrine's **Install Camera
  Support** moves the agent there over SSH),
- the containing app must be signed by a team with `com.apple.developer.system-extension.install`,
  and the extension by the same team, with an app group under that Team ID (the build script names
  it `<TeamID>.<agent bundle ID>` and puts the extension's Mach service under it),
- someone must allow it once in the guest: *System Settings ▸ General ▸ Login Items & Extensions ▸
  Camera Extensions*.

An ad-hoc agent still includes the extension and asks for activation, and the status bar popover
shows why activation was refused. For experiments in a throwaway guest *only*, Apple's
`systemextensionsctl developer on` (in the guest, with SIP disabled in the guest's recovery)
relaxes the location rule. To have an ad-hoc build claim the install entitlement for such a
guest, set `VITRINE_AGENT_SYSTEM_EXTENSION=1`. Unless AMFI is relaxed in that guest, macOS will
refuse to launch the resulting agent.
