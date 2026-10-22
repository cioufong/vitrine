# Storage

Each disk in a VM's `config.json` has a `caching` mode. It decides how Virtualization.framework (VZ)
opens the disk image on the Mac:

| `caching` | Linux guest (VZ) | macOS guest (VZ) | Meaning |
|---|---|---|---|
| `automatic` (default) | host page cache, full sync | framework's choice, full sync | safe default |
| `fast` | host page cache, `fsync` | host page cache, `fsync` | guest flushes reach the Mac's cache, not necessarily the SSD |
| `uncached` | no host cache, full sync | no host cache, full sync | every guest I/O reaches the SSD |

"Full sync" means a guest flush ends in `F_FULLFSYNC`, so data the guest has flushed survives a power loss
of the Mac. QEMU guests ignore this setting.

## Linux guests and VZ's automatic caching

Until 2026-10-21, `automatic` passed `VZDiskImageCachingMode.automatic` for every guest. On Linux guests
this returned wrong data for reads of data that was intact in the disk image:

- Whole 4 KiB pages read as zeros into the guest's page cache. On arm64 a zero word is an undefined
  instruction, so programs mapped from those pages died with SIGILL (`status=4/ILL` in the journal); other
  reads gave `Input/output error`, Python failed with "_frozen_importlib_external is invalid", and once the
  kernel oopsed on a garbage pointer ("Unable to handle kernel paging request at 0016a7f3eaab2661").
- The disk image itself was correct: read back with `O_DIRECT` in the guest, and read by another VM from a
  copy of the image, the same files matched their Debian packages byte for byte. A reboot cleared it.
- Data that the guest *copied* while affected stays wrong. On one VM `update-initramfs` built an initramfs
  from zeroed pages; the next boot stopped in `(initramfs)` with `fsck.ext4: Exec format error`.
- The two zeroed pages that could be located both started a 16 KiB host page (disk-image offsets that are
  multiples of 16 KiB; the guest uses 4 KiB blocks).
- It showed up during the first boot of a one-click Debian 13 VM, while apt installs the desktop, with
  the Mac short of free memory (vm_stat "Pages free" down to about 3,900, i.e. 60 MB). Synthetic I/O loads
  on an already-installed guest (sequential reads of 24 GiB, small-file churn with discards) did not
  trigger it, and neither did a 5 GiB anonymous-memory pattern test.

Fresh one-click Debian 13 installs on the same Mac, checked by comparing every file under `/usr/bin`,
`/usr/sbin` and `/usr/lib` through the page cache against `O_DIRECT` reads, plus `dpkg -V`:

| Disk mode | Installs | Affected | Mac's lowest "Pages free" during the install |
|---|---|---|---|
| `VZDiskImageCachingMode.automatic` | 3 | 3 (SIGILL/EIO and a dead desktop; SSH and console dead, next boot stuck in initramfs; 2 zeroed pages in `libsystemd-core`) | ≈ 3,850 |
| `.cached` | 3 | 0 (21,402 files equal twice, `dpkg -V` clean, desktop up) | 3,878–3,910 |

Three against three on one Mac (2026-10-21, M1 Max, macOS 27.0.1) is not proof that `.cached` can never
show this, only that it removed a failure that hit every install before.

Linux guests now get `.cached` (with full sync) for `automatic`. UTM
([#5919](https://github.com/utmapp/UTM/pull/5919)) and Lima
([#2026](https://github.com/lima-vm/lima/pull/2026), for
[#1957](https://github.com/lima-vm/lima/issues/1957)) made the same change after the same symptoms.
macOS guests keep the framework's default; no corruption has been seen there.

Existing VMs pick up the new mode at their next start; nothing in `config.json` changes. A Linux VM that
ran with the old mode can still have damaged files that were written while it was affected:

```sh
sudo dpkg -V | grep -v ' c /'          # files that differ from their packages
sudo apt-get install --reinstall PKG   # for each package listed
sudo update-initramfs -u -k all
```
