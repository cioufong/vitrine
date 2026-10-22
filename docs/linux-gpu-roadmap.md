# Linux guest 3D acceleration — roadmap (phase 2)

Status 2026-10: Virtualization.framework gives Linux guests 2D virtio-gpu only. Every working macOS-host
3D path depends on unmerged forks; pin exact commits.

## Path 1 — accelerated desktop (GL): UTM-fork QEMU as a child process
- Stack: `utmapp/qemu` (utm-edition, 10.0.x, GPL — separate process only), virglrenderer `macos-next` (MIT),
  libepoxy `macos-venus` (MIT), ANGLE Metal backend (BSD-3), MoltenVK (Apache-2.0) or KosmicKrisp (MIT).
- Display hand-off: QEMU renders through ANGLE into an IOSurface-backed pbuffer and sends its IOSurfaceID
  through SPICE `GL_SCANOUT_UNIX`. Vitrine would implement a minimal Swift SPICE display-channel client
  (GL_SCANOUT_UNIX → `IOSurfaceLookup` → `MTLTexture`, GL_DRAW → blit, GL_DRAW_DONE), avoiding LGPL spice-gtk.
- Command line sketch:
  `qemu-system-aarch64 -M virt -accel hvf,ipa-granule-size=0x1000 -cpu host -m 8G
   -device virtio-gpu-gl-pci,hostmem=8G,blob=true,venus=true -spice unix=on,addr=vm.sock,disable-ticketing=on,gl=es`
- Guest: `CONFIG_DRM_VIRTIO_GPU`, Mesa virgl for the compositor; Venus (Mesa ≥ 24.2, kernel ≥ 5.16) for apps.
- Quick prototype: `brew tap milesbuckton/qemu-virgl` + `-display cocoa,gl=es` (window lives in QEMU).

## Path 2 — Vulkan compute (all permissive): libkrun

**Tried 2026-10-17 with krunkit 1.1.1 (Homebrew tap slp/krunkit):** a Debian 13 disk booted under
`krunkit --device virtio-gpu,...` exposes *Virtio-GPU Venus (Apple M1 Max)* — Vulkan 1.2, 70+
extensions — to the guest, **but only with a 16K-page kernel** (`linux-image-arm64-16k`); with 4K pages
libkrun can't map the host-visible blob memory (`Error adding memory map`, guest gets
`VK_ERROR_OUT_OF_HOST_MEMORY`). There is no scanout (KMS disabled, no `VK_KHR_swapchain`), so it serves
compute/offscreen work only; vkmark and desktops need the display API (libkrun ≥ 1.15
`krun_set_display_backend` callbacks). The 16K kernel boots fine under VZ too.

- `krun_create_ctx → krun_set_vm_config → krun_set_firmware(EFI) → krun_add_disk2 →
  krun_set_gpu_options2(VENUS|NO_VIRGL) → krun_start_enter` in a helper process.
- Display later via `krun_set_display_backend` (CPU frames) as fxgl/steamac does (needs patches).

## Path 3 — VZ-native (watch)
`VZCustomVirtioDevice` (macOS 27) could host a virtio-gpu device inside VZ, but today lacks a config-write
callback and any scanout object. Revisit each macOS release.

## Not viable
Upstream QEMU cocoa/dbus/spice GL on macOS, gfxstream/rutabaga, crosvm, DRM native context.
