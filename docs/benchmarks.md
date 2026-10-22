# Guest performance vs. the Mac (acceptance benchmark)

Measured 2026-10-17 on a MacBook Pro M1 Max (8 performance + 2 efficiency cores, 64 GB, macOS 27),
one VM running at a time, every guest with 4 vCPUs. Scripts: `scripts/bench/bench-unix.sh` (macOS/Linux),
`scripts/bench/bench-win.ps1` (Windows) and `scripts/bench/gpu-probe.sh`; the same **7-Zip 26.04** build family is used
everywhere (`7zz b`, LZMA rating in MIPS), because ratings differ between 7-Zip releases.

## CPU (7-Zip 26.04, MIPS — higher is better)

| System | Backend | 1 thread | % of Mac | 4 threads | % of Mac |
|---|---|---:|---:|---:|---:|
| Mac (host) | — | 6 330 | 100% | 28 025 | 100% |
| macOS 27 guest | Virtualization.framework | 6 164 | **97%** | 27 191 | **97%** |
| Debian 13 guest | Virtualization.framework | 6 073 | **96%** | 21 706 | 77% |
| Windows 11 on Arm | QEMU + HVF | 5 657 | **89%** | 26 735 | **95%** |
| Windows 11 x64 (emulated) | QEMU TCG | 1 097 | 17% | 4 255 | 15% |

- **x64 apps on Windows on Arm** (Prism emulation), same VM, measured back to back with the Arm64
  build: 7-Zip 26.04 x64 rates 4 107 (1 thread) / 17 165 (4 threads) against 5 573 / 25 959 for
  Arm64 — **65% / 61% of the Mac**, about 70% of native guest speed. (The x64 build also runs
  different, hand-written x86 assembly, so this is "what an x64 app gets", not a pure emulator ratio.)
- **A whole x64 Windows VM** (Windows 11 26H2 x64, QEMU TCG with `Westmere-v2`, 4 vCPUs, 8 GB) — every
  instruction emulated: 7-Zip 26.04 x64 rates **1 097** (1 thread) / **4 255** (4 threads) = **17% / 15%
  of the Mac**, a quarter of what the same x64 build gets under Prism on Windows on Arm. Measured right
  after setup, so Windows' own first-boot work may cost a little. Use Windows on Arm for x64 apps; a full
  x64 VM is only for software that needs x64 drivers or kernel code.

  **Emulator tuning** (2026-10-18, same VM, each variant a cold boot, Windows Update paused while
  measuring, two runs each; the host was not idle, so 4-thread figures vary by ±15%):

  | Variant | 1 thread | 4/8 threads | QEMU host CPU, guest idle |
  |---|---:|---:|---:|
  | Baseline (`Westmere-v2`, 4 vCPUs, 1 GB translation cache) | 1 077 / 1 070 | 3 641 / 3 708 | 278% |
  | + Hyper-V enlightenments | 1 202 / 1 160 | 4 426 / 4 223 | 115% |
  | 2 GB translation cache | 1 110 / 1 098 | 3 938 / 4 540 | 179% |
  | 8 vCPUs | 1 111 / 1 117 | 6 772 / 6 834 | 354% |
  | Hyper-V + 8 vCPUs | 1 119 / 1 139 | 8 330 / 6 777 | 362% |

  Windows x64 guests now get the enlightenments (`hv-relaxed,hv-vapic,hv-spinlocks,hv-vpindex,hv-time`)
  by default: about +10% single-thread, +18% multi-thread. Eight vCPUs nearly double the multi-thread
  rating (up to 30% of the Mac) but keep 3–4 host cores busy even while Windows idles. **A new x64 guest
  now defaults to `min(8, cores − 2)` vCPUs** (`WindowsCreator.Options.defaultCPUCount`), because an
  emulated guest is throughput-bound and the half-the-cores default that suits Arm guests left it slow;
  Arm64 guests keep the old default. Lower it in the VM's hardware settings if the host feels sluggish
  while the guest idles. The larger translation cache made no measurable difference (7-Zip fits in 1 GB;
  Setup filled it once), so it stays at 1 GB. A freshly booted guest spends its first hour on Windows
  Update servicing (`TiWorker`, about 2 vCPUs' worth), which cuts multi-thread results by up to 40%
  until it finishes.

  The first install took about 5 hours with two manual steps: OOBE's zero-day-patch check timed out
  (`OOBEZDP`, needed "Skip") and the first-logon script's `Add-WindowsCapability OpenSSH.Server`
  crawled for 2 h before it was cancelled. Now the emulated x64 setup runs offline, skips OOBE's
  screens (offline, OOBE's watchdog otherwise declares the slow user OOBE hung and reboots into "Why
  did my PC restart?") and installs OpenSSH from the MSI on the seed disc: a fresh Windows 11 x64 VM
  installs **unattended in 1 h 53 min** (2026-10-18; Windows on Arm: 20 min) and comes up with SSH and
  the agent connected. The agent missed the 10 s keepalive under load, so emulated guests get 60 s.
- Windows was at 65% / 76% before commit `1ee54f6`: QEMU's vCPU threads ran at the default QoS and
  macOS parked a lone busy vCPU on an efficiency core. QEMU now runs user-interactive, like
  Virtualization.framework's VM process.
- The Linux 4-thread figure is lower with every backend tried and the macOS guest on the same
  framework reaches 97%, so it reflects the Linux 7-Zip build/kernel rather than the hypervisor.
- Baselines must be taken with all VMs suspended: with three VMs streaming Coherence frames the
  Mac's own single-thread rating dropped from 6 330 to 4 273.

## Disk (as applications see it)

| System | Tool | Seq. write | Seq. read | 4K random read |
|---|---|---:|---:|---:|
| Mac (host) | fio, buffered | 5.6 GB/s | 2.1 GB/s | 16.7 k IOPS |
| macOS guest | dd 2 GiB | 2.9 GB/s | 12.8 GB/s | — |
| Debian guest | fio, O_DIRECT | 8.2 GB/s | 23.8 GB/s | 778 k IOPS |
| Windows guest | DiskSpd, unbuffered | 8.0 GB/s | 7.6 GB/s | 42.2 k IOPS |

Guest numbers above the SSD's physical limits come from the Mac's page cache: Vitrine opens disk
images with host caching ("automatic" for macOS and Windows guests, "cached" for Linux guests since
commit `ec9be81`, see [storage.md](storage.md)), so a guest's unbuffered I/O is still served from host RAM.
That is what guests get in practice, but it is not raw SSD throughput.

## Memory

sysbench 1 MiB sequential writes: Mac 22.9 GB/s, Debian guest 36.2 GB/s. The Linux and macOS
sysbench builds differ too much for a percentage; no regression is visible.

## GPU

| Guest | Path | Result |
|---|---|---|
| macOS | Paravirtualized Metal (VZ) | Apple GPU used directly (not benchmarked) |
| Linux (VZ) | virtio-gpu 2D, Vulkan through llvmpipe (CPU) | vkmark 616 |
| Linux (krunkit experiment) | virtio-gpu **Venus** → MoltenVK → Metal | Vulkan 1.2 device *Virtio-GPU Venus (Apple M1 Max)*, 70+ extensions; needs a 16K-page guest kernel (`linux-image-arm64-16k`; with 4K pages blob memory can't be mapped). No swapchain (krunkit has no display), so vkmark can't run |
| Windows | virtio-gpu 2D (viogpudo) | no 3D acceleration |

## Pass criteria

CPU single thread ≥ 85% and 4 threads ≥ 75% of the Mac with one VM running: **all three guests pass**.
Open: Linux 3D desktops (needs a display path for Venus, see `linux-gpu-roadmap.md`) and Windows 3D.

## Re-run, 2026-10-20 (after networking, camera, Bluetooth and status bar work)

Same Mac and scripts, Debian 13 guest `hash-test` (5 vCPUs, 4 GB, headless) on Virtualization.framework. The
host was busy: Docker Desktop's VM and browsers were running (and the guest itself stayed up, idle, during the
Mac's run), macOS had about 23 GB in
the memory compressor and 6.6 GB of swap, and the boot volume had 38 GiB free.

| | Mac (host) | Debian guest | % of Mac |
|---|---:|---:|---:|
| 7-Zip, 1 thread (MIPS) | 6 493 | 6 216 | **96%** |
| 7-Zip, 4 threads (MIPS) | 31 705 | 29 205 | **92%** |
| sysbench memory write | 22.9 GB/s | 35.8 GB/s | — |
| fio seq. write | 2.9 GB/s | 0.57–0.79 GB/s | — |
| fio seq. read | 2.2 GB/s | 0.42–2.0 GB/s | — |
| fio 4K random read | 27.4 k IOPS | 6.4–6.9 k IOPS | — |

- CPU still passes, and the guest's 4-thread result is now 92% of the Mac (77% on 10-17, with 4 vCPUs).
- Guest disk numbers are far below 10-17 although the disk attachment (automatic caching, full
  synchronization) has not changed since the first commit. Under this memory pressure macOS no longer keeps
  the disk image in its page cache, so every guest I/O reaches the SSD: 4K random reads cost about 150 µs
  each, and sequential results vary by 4× between runs. The 10-17 figures show what guests get on a Mac
  with free memory; these show the floor on a loaded one. Compare disk results only between runs with
  similar memory pressure (`memory_pressure`, `sysctl vm.swapusage`). (Linux guests no longer use automatic
  caching; see the 2026-10-21 Linux disk caching section below.)

## Standard benchmarks, 2026-10-21 (Phoronix Test Suite, fio, iperf3, Cinebench R23)

Free, widely published tools instead of our own scripts, so results can be compared with other machines.
Same Mac; the Mac kept its usual background load (Docker Desktop, browsers, several Node and Bun services;
load average 12–25, about 60% memory free, 3.8 GB swap), so absolute host figures sit below a clean M1 Max
(Cinebench R23 multi-core is usually about 12 000). Every guest ran alone.

- **PTS 10.8.4**, uploads and usage reporting off, batch mode. Each test runs until its results are stable,
  so noisy host runs got up to 15 repetitions. Options: `c-ray` 1080p/16 rays, `openssl` SHA256 and RSA4096,
  `stream` Copy and Triad, `compress-7zip`, `sqlite-speedtest`; `coremark` builds only on Linux. PTS builds the
  tests from source on each system, so macOS (Clang 23) and Debian (GCC) binaries differ.
- **fio** on a 4 GiB file with direct I/O, 30 s per job after a 5 s ramp (`posixaio` on macOS, `libaio` in Linux).
- **iperf3**, 15 s per run: the guest is the server and the Mac connects out (no firewall prompt).
- **Cinebench R23** from the command line, one pass (`g_CinebenchMinimumTestDuration=1`).

Guests: Debian 13 `hash-test` (5 vCPUs, 4 GB) and macOS 27 `bench-macos-fresh` (4 vCPUs, 8 GB), both on
Virtualization.framework, NAT networking. The Mac has 10 cores (8 performance + 2 efficiency), so
multi-threaded results compare 4–5 virtual CPUs against all 10.

### CPU and memory

| Test | Mac (10 cores) | Guest | Guest / Mac |
|---|---:|---:|---:|
| Cinebench R23 single core | 1 434 | 1 410 (macOS) | **98%** |
| Cinebench R23 multi core | 8 406 | 5 450 (macOS, 4 vCPUs) | 65% |
| 7-Zip compression, MIPS | 60 182 | 42 031 (Debian, 5 vCPUs) | 70% |
| 7-Zip decompression, MIPS | 38 948 | 22 752 | 58% |
| OpenSSL SHA256, GB/s | 9.21 | 6.96 | 76% |
| OpenSSL RSA4096 sign/s | 1 885 | 1 331 | 71% |
| OpenSSL RSA4096 verify/s | 123 601 | 91 982 | 74% |
| C-Ray 1080p, s (lower is better) | 80.6 (67–116 between runs) | 73.9 | — |
| CoreMark, iterations/s | — | 146 294 | — |
| STREAM Copy, GB/s | 180.9 | 155.5 | 86% |
| STREAM Triad, GB/s | 151.7 | 145.8 | 96% |

- A single guest CPU runs at the speed of a Mac core (Cinebench single core 98%).
- With half the Mac's cores the Debian guest reaches 58–76% of the whole Mac, and the macOS guest 65% with
  four. Throughput per virtual CPU is above the Mac's per-core average, most likely because the virtual CPUs run
  on performance cores while the Mac's own total includes its two efficiency cores.
- Memory bandwidth is nearly the host's (86–96%).
- C-Ray varied most on the Mac (67–116 s) as background work came and went, and the two systems use
  different compilers, so the two C-Ray figures are not directly comparable.

### Disk (fio, direct I/O)

| Job | Mac | Debian guest | Guest / Mac |
|---|---:|---:|---:|
| Sequential write 1M QD8 | 1.83 GB/s | 2.27 GB/s | 124% |
| Sequential read 1M QD8 | 6.35 GB/s | 4.29 GB/s | 68% |
| Random read 4K QD32 | 128.9 k IOPS | 52.0 k IOPS | 40% |
| Random write 4K QD32 | 27.4 k IOPS | 64.5 k IOPS | 235% |
| Random read 4K QD1 | 10.2 k IOPS (98 µs) | 7.8 k IOPS (127 µs) | 77% |

These figures were taken with automatic caching, before Linux guests moved to cached mode (next section).
The guest's direct I/O ends at the virtual disk, and Virtualization.framework's automatic caching may still
buffer it in the Mac's memory; that's why guest writes can beat the Mac's own direct writes. Reads that miss
the cache pay for the extra hop: about 30 µs per 4K read at queue depth 1. The SQLite speedtest shows the same
effect (49.8 s in the guest vs 75.7 s on the Mac, where SQLite's fsync becomes a full flush to the SSD).

### Network (iperf3, NAT)

| Direction | 1 stream | 4 streams |
|---|---:|---:|
| Mac → guest | 46.3 Gbit/s | 41.5 Gbit/s |
| guest → Mac | 65.7 Gbit/s | 73.8 Gbit/s |

Traffic between the Mac and a NAT guest never leaves memory, so these figures are far above any physical link;
the guest's outside connections are limited by the Mac's own network.

## Linux disk caching change, 2026-10-21 (commit `ba4dd13`)

Linux guests on Virtualization.framework now attach their disk with **cached** caching and full
synchronization instead of automatic, because automatic caching handed Linux guests zeroed 4 KiB pages
and corrupted fresh installs ([storage.md](storage.md)). Re-measured on a freshly installed Debian 13 Xfce
guest `ab-b3` (4 vCPUs, 8 GB, Vitrine.app, Firefox closed), with the Mac measured right after while the
guest was suspended. The Mac was heavily loaded the whole time: load average 280–380, 6.5 of 7 GB swap in
use and about 3 million pages in the memory compressor, so absolute figures sit well below earlier runs.

| | Mac (host) | Debian guest | % of Mac |
|---|---:|---:|---:|
| 7-Zip, 1 thread (MIPS) | 5 559 | 4 689 | 84% |
| 7-Zip, 4 threads (MIPS) | 21 600 | 20 945 | 97% |
| sysbench memory write | 19.0 GB/s | 33.5 GB/s | — |

fio, same five jobs as above (4 GiB file, direct I/O, 5 s ramp + 30 s each):

| Job | Mac | Debian guest (cached) | Debian guest (automatic, 10-21 above) |
|---|---:|---:|---:|
| Sequential write 1M QD8 | 2.41 GB/s | 4.00 GB/s | 2.27 GB/s |
| Sequential read 1M QD8 | 6.12 GB/s | 7.28 GB/s | 4.29 GB/s |
| Random read 4K QD32 | 86.7 k IOPS | 206.3 k IOPS | 52.0 k IOPS |
| Random write 4K QD32 | 23.5 k IOPS | 79.1 k IOPS | 64.5 k IOPS |
| Random read 4K QD1 | 8.3 k IOPS (115 µs) | 16.1 k IOPS (51 µs) | 7.8 k IOPS (127 µs) |

- Cached mode serves the guest's direct I/O from the Mac's page cache, so the guest now beats the Mac's own
  direct I/O on every job, and the extra hop measured with automatic caching (about 30 µs per QD1 read) is
  gone. The cost is host memory: the disk image stays in the Mac's page cache like any other file. The
  automatic column comes from a different guest (`hash-test`, 5 vCPUs, 4 GB) on a less loaded Mac, so
  compare it for direction, not exact ratios.
- The single-thread CPU figure (84%) sits just under the 85% pass line. Under this load the guest and the
  Mac ran ten minutes apart (load 277 vs 380); the 10-20 and PTS runs above show 96% on a calmer host.

### Display (key → pixel latency and delivered frame rate)

`scripts/bench/display-probe.py` against `display-probe.html` full screen in the guest's Firefox ESR
(`--kiosk`), through Vitrine's control socket, same Debian guest and same load as above:

| | Result |
|---|---|
| Frames delivered to the Mac (`#fps`) | 28.1 fps (the guest's own `requestAnimationFrame` ran at 56 fps) |
| Key → pixel, 40 samples (`#latency`), two runs | median 49.2 / 47.6 ms, p95 78.2 / 63.3 ms, none missed |
