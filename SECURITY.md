# Security policy

## Reporting a vulnerability

Please report security problems privately through GitHub's
[private vulnerability reporting](https://github.com/cioufong/vitrine/security/advisories/new)
rather than in a public issue. Include the Vitrine version or commit, the host macOS version, the
guest OS, and steps to reproduce. You should get an acknowledgement within a week.

## Scope and design notes

Vitrine runs guests that you install and treats a guest as less trusted than the host. Reports that
are especially useful:

- **Guest-to-host escapes through Vitrine's own code**: the agent protocol parsers
  (`Sources/VitrineAgentProtocol`), the clipboard and file-drop paths, the guest-app Dock proxies, and
  the per-VM control socket.
- **Credential exposure.** The guest account password is stored in the VM bundle as
  `guest-account.secret` (mode 0600) so Vitrine can install and update its agent over SSH. Unattended
  setup media contain the password until setup finishes; Vitrine deletes its generated seed disc
  afterwards. Cloud-init seeds for Linux guests grant the created user passwordless sudo.
- **The Windows agent transport.** The agent talks over virtio-serial by default. The optional TCP
  transport (`--tcp`) authenticates with a per-VM token passed through SMBIOS and accepts only the
  NAT gateway address; treat it as weaker than virtio-serial.
- **Shared folders.** Windows guests reach shared folders through a per-run Samba instance that QEMU
  starts for connections from inside the VM (guest forwarding to 10.0.2.4); it does not listen on the
  host network, and it uses a random per-run account with SMB signing required.

Out of scope: vulnerabilities in QEMU, Samba, swtpm or the guest operating systems themselves (report
those upstream), and attacks that need an already compromised host account.
