# Bluetooth (experimental)

Neither Virtualization.framework nor QEMU can give a guest the Mac's Bluetooth: VZ has no Bluetooth
device, and the Mac's controller can't be passed through as USB. Vitrine instead **emulates a
Bluetooth LE controller** on the host and plugs it into the guest's kernel through the guest agent.
The guest's own stack (BlueZ) sees an ordinary controller, `hci0`. Everything it asks for goes out
over the Mac's Bluetooth through CoreBluetooth: scans become CoreBluetooth scans, connections
become CoreBluetooth connections, GATT reads, writes and notifications are relayed.

| Guest   | Support |
|---------|---------|
| Linux   | Bluetooth LE: scanning, connecting, GATT client (read, write, notify). Needs the `hci_uart` module (in Debian, Ubuntu and Fedora kernels). |
| macOS   | No: macOS has no way to add an HCI controller from user space. |
| Windows | No. |

Classic Bluetooth (BR/EDR: audio, keyboards over HID, serial ports) isn't possible this way,
because CoreBluetooth only speaks LE. To use a classic device, or an LE device with features
CoreBluetooth hides, pass a USB Bluetooth dongle through to a QEMU VM instead (Configuration ▸
USB & Bluetooth).

## Using it

1. Start a Linux VM with the Vitrine agent running.
2. Click the Bluetooth switch (radio waves) in the VM window's status bar. The first time, macOS
   asks whether Vitrine may use Bluetooth.
3. If the guest isn't set up yet, a popover offers **Install Bluetooth Support**. Vitrine logs in
   over SSH with the VM's guest account and then:
   - installs BlueZ;
   - loads `hci_uart` at boot;
   - adds the root service `vitrine-bluetooth` (`vitrine-agent bluetooth-bridge`).

   Sharing starts when the install is done. The same install is `vitrinectl agent bluetooth <vm>`.
4. In the guest, use Bluetooth as usual: `bluetoothctl scan le`, `bluetoothctl connect <address>`,
   the desktop's Bluetooth settings, or any BlueZ/D-Bus program.

The controller exists only while the switch is on. Clicking it again, stopping the VM or losing the
agent removes `hci0` from the guest.

## What the guest sees

- An LE-only Bluetooth 4.2 controller with a fixed public address derived from the VM's identifier.
  The manufacturer is 0xFFFF, which means none.
- Peripherals appear under **random static addresses** derived from CoreBluetooth's identifiers for
  them. macOS never reveals a peripheral's real address, so the address a guest sees isn't the
  device's own. It is stable for that device on this Mac, so BlueZ can reconnect to devices it
  remembers.
- Advertisements are rebuilt from what CoreBluetooth parsed: flags, name, service UUIDs,
  manufacturer data, service data and Tx power. With active scanning, what doesn't fit in 31
  bytes moves to the scan response. Raw advertising data and other AD types are lost.
- After a connection, the GATT database is CoreBluetooth's view of the device: its services,
  characteristics and descriptors, plus a synthesized GAP service with the device's name.
  Attribute handles are numbered by Vitrine, not taken from the device.
- **Pairing happens on the Mac.** When the device requires encryption, macOS pairs with it itself
  and may show its own pairing prompt. The guest's pairing requests (SMP) are refused with
  *Pairing Not Supported*. Bonding information stays on the Mac.
- Not supported: advertising from the guest, the guest acting as a peripheral, L2CAP
  connection-oriented channels, LE Audio, and Bluetooth 5 extended advertising.

## How it works

```
guest kernel (BlueZ)  ⇄ hci_uart line discipline on a pty  (vitrine-bluetooth service, root)
                      ⇄ /run/vitrine/bluetooth.sock        (H4 packets; only the desktop user)
                      ⇄ vitrine-agent (user session)
                      ⇄ bluetoothStart / bluetoothHCI / bluetoothStop / bluetoothStatus (0x32–0x35)
host:  BLEController (HCI commands and events, ACL, L2CAP, ATT server) ⇄ CoreBluetooth
```

- **Root bridge (`guest/linux-agent/btbridge`).** For each connection to its socket, the bridge
  opens a pseudo-terminal and puts it in raw mode. It then attaches the `N_HCI` line discipline,
  selects the H4 protocol (`HCIUARTSETPROTO`) and replies `ok hciN`. The kernel registers the
  controller at once and starts initializing it. Closing the connection detaches the discipline,
  and the controller disappears. Root is needed only to attach the line discipline. Debian's arm64
  kernel has no `hci_vhci` module, but `hci_uart` is everywhere.
- **Agent.** Splits the byte stream into H4 packets (command, ACL, SCO, event, ISO) and relays them
  as `bluetoothHCI` messages. Agents announce `bluetooth` in their Hello only on Linux.
- **Host controller (`Sources/VitrineAgentHost/Bluetooth`).**
  - `BLEController` answers the HCI commands Linux sends while initializing and running a
    controller. *Read Local Supported Commands* lists exactly the commands it handles; anything
    else gets *Unknown HCI Command*.
  - It maps *LE Set Scan Enable* to a CoreBluetooth scan and *LE Create Connection* to a
    connection plus full GATT discovery.
  - It reassembles ACL fragments into L2CAP, credits the host's buffers (*Number Of Completed
    Packets*) and refuses signaling and SMP requests politely.
  - `ATTServer` serves the guest's ATT requests: MTU 247, discovery, (blob) reads, writes,
    prepared writes, and CCCD writes, which become CoreBluetooth `setNotifyValue`.
  - `CoreBluetoothRadio` is the CoreBluetooth backend.
  - Unit tests drive the controller with a fake radio (`BLEControllerTests`).
- Timing differs from real hardware: *LE Connection Complete* comes only after CoreBluetooth has
  connected and discovered the whole GATT database. That takes a few seconds on large devices, which
  is within the kernel's connection timeout.

## Tested

On an M1 Max (macOS 27.0.1) with a Debian 13 arm64 guest (kernel 6.12, BlueZ 5.82):

- `hci0` comes up powered (`bluetoothctl show`: version 8, manufacturer 0xffff).
- `bluetoothctl scan le` lists nearby devices, connectable and non-connectable.
- `bluetoothctl connect` to a Linksys router's setup service succeeds. BlueZ discovers the GATT
  database: the synthesized GAP service plus the vendor service, with a CCCD on its notify
  characteristic.
- D-Bus `ReadValue` returns every readable characteristic, including the device name from GAP.
- Not yet tried on a real device: writes, and notifications arriving from the device. The unit
  tests cover both.

## Troubleshooting

- *"The guest's Bluetooth bridge isn't running"*: install Bluetooth support, or check
  `systemctl status vitrine-bluetooth` in the guest.
- *"Vitrine isn't allowed to use Bluetooth"*: allow it in System Settings ▸ Privacy & Security ▸
  Bluetooth.
- Nothing found when scanning: check that Bluetooth is on on the Mac. A device already connected to
  the Mac may not be advertising.
- Guest logs: `journalctl -u vitrine-bluetooth`, `btmon` (shows the HCI traffic), and the agent's
  `journalctl --user -u vitrine-agent`. Host log: the VM's `vitrine.log`.
