# Camera

Neither Virtualization.framework nor QEMU has a virtual camera device, so Vitrine shares the Mac's
camera through the guest agent instead: the host captures, the agent writes the frames into a
virtual webcam in the guest, and guest apps (browsers, Zoom, `ffmpeg -f v4l2`, OBS) see an
ordinary camera called **Vitrine Camera**.

| Guest   | Support |
|---------|---------|
| Linux   | Yes, through [v4l2loopback](https://github.com/umlaeute/v4l2loopback) |
| macOS   | With a team-signed agent: the agent's *Vitrine Camera* CoreMediaIO extension ([signing.md](signing.md#the-macos-guest-camera)) |
| Windows | Windows 11 (build 22000+): a Media Foundation virtual camera, no driver (tested on Windows 11 26H2 Arm64) |

An external USB webcam can also be passed through on QEMU VMs (USB & Bluetooth settings).

## Using it

1. Start the VM with the Vitrine agent running (the status bar shows the guest OS, not "No agent").
2. Click the camera switch in the VM window's status bar (View ▸ Show Status Bar, ⌘/). macOS asks
   for camera permission the first time.
3. If the guest has no virtual camera yet, a popover offers **Install Camera Support**: Vitrine logs
   in over SSH with the VM's guest account and installs v4l2loopback (needs the guest's internet
   connection; DKMS builds the module, a few minutes on a small VM). The camera starts when it's
   done. The same install is `vitrinectl agent camera <vm>`.

In a **macOS guest**, **Install Camera Support** moves the agent from `~/Applications` to
`/Applications` (macOS activates system extensions only from there) and restarts it. The next
start asks macOS to activate the Vitrine Camera extension. The guest then shows an approval
prompt (*System Settings ▸ General ▸ Login Items & Extensions ▸ Camera Extensions*). Click the
switch again once you've allowed it. An ad-hoc agent gets this far too, but macOS refuses the
activation, and the popover says so.

In a **Windows guest**, Install Camera Support copies `vitrine-camera.dll`, a Media Foundation
media source (`guest/windows-camera`), to `C:\Program Files\Vitrine` and registers it machine-wide.
When you turn the camera on, the agent calls `MFCreateVirtualCamera`. Windows's Camera Frame
Server then loads the media source as LocalService. The source reads the Mac's frames from the
agent over the named pipe `\\.\pipe\vitrine-camera`. Only SYSTEM, LocalService, administrators and
the logged-in user can open that pipe. The source offers NV12 and YUY2 at 1280×720 and 640×480,
30 fps, scaled from whatever the Mac sends, and shows black while no frames arrive. Apps list the
camera as *Vitrine Camera (Windows Virtual Camera)*. It exists only while sharing is on and
disappears a few seconds after the switch goes off. Camera access and *Let desktop apps access
your camera* must be on in Settings ▸ Privacy & security ▸ Camera. Windows 10 has no virtual
camera API. The DLL is built with zig (`scripts/build-windows-agent.sh`).

Tested on Windows 11 26H2 Arm64 (build 26300) on the QEMU backend: the Windows Camera app and
WinRT `MediaCapture` show the Mac's camera live at about 27 fps in all four formats. Things that
look like camera faults there but aren't:

- The Camera app shows *We need your permission* while its **microphone** switch is off
  (Settings ▸ Privacy & security ▸ Microphone ▸ Camera), even though the guest has no microphone.
  Answering *No* to its microphone prompt is enough to cause it.
- On that guest, Windows's own YUY2-to-RGB conversion (`SoftwareBitmap.Convert`, and photos taken
  from a YUY2 stream) gives a white image for any input, synthetic frames included. The source's
  YUY2 frames are correct; NV12, the default that apps get unless they ask for YUY2, converts fine.
- A format an app picks stays selected for the next app until the switch is turned off and on.

The camera is on only while the switch is on: the Mac's camera light shows it, nothing is captured
at startup, and stopping the VM, losing the agent or clicking the switch again stops the capture.

## How it works

```
AVCaptureSession (YUYV 422, 1280×720 or 640×480, 30 fps)
  → cameraStart{width,height,fps}, then cameraFrame{u32 w, u32 h, YUYV bytes} over the agent channel
  → agent: VIDIOC_S_FMT (OUTPUT, YUYV) on the "Vitrine Camera" /dev/videoN, write() per frame
  → cameraStatus{ready, device | error} back to the host
```

- Messages `0x2C`–`0x2F`; only sent to agents whose Hello lists `camera` (older agents drop the
  channel on unknown types).
- Back-pressure: the host drops a frame when more than about two frames are still queued for the
  guest, so a slow guest gets a lower frame rate rather than growing latency.
- A frame of a different size makes the agent reopen the device at that size.
- The installer writes `/etc/modprobe.d/vitrine-camera.conf`
  (`card_label="Vitrine Camera" exclusive_caps=1 devices=1`; `exclusive_caps` is what makes Chrome
  and WebRTC apps accept a loopback device), `/etc/modules-load.d/vitrine-camera.conf` and a udev
  rule tagging the device `uaccess`, so the desktop user's session can open it. If v4l2loopback is
  already loaded for something else (OBS), it adds a device with `v4l2loopback-ctl` instead of
  unloading it.
- Package managers: apt (`v4l2loopback-dkms`), dnf (`v4l2loopback`, RPM Fusion on Fedora), pacman,
  zypper. Guests with Secure Boot enabled need the DKMS signing key enrolled (MOK) before the module
  loads.

macOS guests: the agent finds the extension's *Vitrine Camera Input* sink stream through the
CoreMediaIO C API (`CMIOStreamCopyBufferQueue`, `CMIODeviceStartStream`) and enqueues each frame
as a `yuvs` `CMSampleBuffer`, dropping frames while the queue is full. The extension
(`guest/macos-camera-extension`) passes every buffer from the sink stream to the *Vitrine Camera*
source stream that apps open. The Linux and macOS agents answer with the same `cameraStatus`;
its `installable` field tells the host whether Install Camera Support can fix the problem, or
whether something in the guest has to change, such as an approval or the signing.

Bandwidth is about 55 MB/s at 1280×720 YUYV 30 fps, comfortably within vsock and virtio-serial.
