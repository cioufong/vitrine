import Foundation
import VitrineCore

/// Growing the system disk.
extension VirtualMachineController {
    /// Why the system disk can't grow. The app shows its own translated text for each case.
    public enum DiskGrowBlocker: Equatable, Sendable {
        case macOSGuest, running, inUse(pid: Int32), suspended

        public var message: String {
            switch self {
            case .macOSGuest: "macOS keeps its Recovery partition behind the system container, so the container can't take extra space. Create the VM with a larger disk instead."
            case .running: "Shut the VM down first."
            case .inUse(let pid): "The VM is in use by another process (pid \(pid))."
            case .suspended: "The VM is suspended: start it and shut it down (a saved state expects the current disk size)."
            }
        }
    }

    /// Why the system disk can't grow, or nil if it can (VM shut down, not suspended).
    public var diskGrowBlocker: DiskGrowBlocker? {
        if config.guestOS == .macOS { return .macOSGuest }
        if state != .stopped && state != .error { return .running }
        if let owner = bundle.lockOwner(), owner.pid != getpid() { return .inUse(pid: owner.pid) }
        if hasSavedState { return .suspended }
        return nil
    }

    /// Current capacity of the system disk as the guest sees it.
    public var systemDiskCapacity: UInt64? {
        config.disks.first.flatMap { DiskImage.virtualSize(of: systemDiskFile($0)) }
    }

    /// `systemDiskCapacity` for UI: an ASIF image is measured with `diskutil`, which takes a moment.
    public func loadSystemDiskCapacity() async -> UInt64? {
        guard let disk = config.disks.first else { return nil }
        let file = systemDiskFile(disk)
        return await Task.detached { DiskImage.virtualSize(of: file) }.value
    }

    /// The image file itself: a symlinked disk is measured and resized at its target (the link's
    /// own size says nothing, and truncating through it could shrink the real image).
    private func systemDiskFile(_ disk: VMConfig.DiskConfig) -> URL {
        bundle.resolve(disk.path).resolvingSymlinksInPath()
    }

    /// Enlarges the system disk image. The guest's partition is extended on the next start:
    /// Linux cloud images do it at boot (cloud-init growpart), Windows through its agent session.
    /// Runs under the bundle lock, so no other process can start the VM (or snapshot it) meanwhile.
    public func growSystemDisk(to bytes: UInt64) throws {
        if let reason = diskGrowBlocker { throw VitrineError.invalidConfig(reason.message) }
        try bundle.withExclusiveLock {
            try saveConfig(growSystemDiskWhileLocked(to: bytes, proposedConfig: bundle.loadConfig()))
        }
        log.write("system disk grown to \(formatBytes(bytes)); the guest partition is extended on next start")
    }

    /// Used by a larger config transaction (vitrinectl set). The caller owns the bundle lock and
    /// commits the returned, already validated config; this method never reacquires the lock.
    public func growSystemDiskWhileLocked(to bytes: UInt64, proposedConfig: VMConfig) throws -> VMConfig {
        guard bundle.lockOwner()?.pid == getpid() else { throw VitrineError.backend("disk growth requires the VM lock") }
        guard proposedConfig.guestOS != .macOS else { throw VitrineError.invalidConfig("macOS system disks cannot be grown") }
        if hasSavedState { throw VitrineError.invalidConfig("The VM is suspended: start it and shut it down first.") }
        try proposedConfig.validate(bundle: bundle)
        guard let disk = proposedConfig.disks.first, let current = DiskImage.virtualSize(of: systemDiskFile(disk)) else {
            throw VitrineError.invalidConfig("no system disk")
        }
        guard bytes > current else { throw VitrineError.invalidConfig("the disk is already \(formatBytes(current))") }
        try DiskImage.resize(at: systemDiskFile(disk), to: bytes)
        var grown = proposedConfig
        grown.pendingDiskGrow = true
        return grown
    }

    /// Runs when the VM starts: once the guest answers over SSH, extends its system partition into
    /// the new disk space (retries for a few minutes while it boots). A failing command isn't
    /// retried on later starts; the log says what to do by hand.
    func extendGuestPartitionIfNeeded() {
        guard config.pendingDiskGrow == true else { return }
        let bundle = self.bundle, os = config.guestOS
        guard os != .macOS, config.account != nil else {
            finishDiskGrow("could not extend the guest partition: Vitrine has no account to sign in to the guest with; extend it in the guest's disk utility")
            return
        }
        let diskBytes = systemDiskCapacity ?? 0
        let windowsScript = Self.windowsExtendScript(diskBytes: diskBytes)
        let generation = runGeneration
        Task { [weak self] in
            var lastError: Error?
            var restarted = false
            for _ in 0..<60 {
                // Only for the run that started it: a stop (or a restored snapshot) ends the job.
                guard let self, self.state == .running, self.runGeneration == generation else { return }
                do {
                    let output = os == .windows
                        ? try await AgentInstaller.runPowerShell(in: bundle, script: windowsScript, name: "vitrine-extend-disk.ps1")
                        : try await AgentInstaller.run(in: bundle, command: Self.linuxExtendCommand)
                    if output.contains(Self.restartMarker) {
                        // Windows resumed from Fast Startup with the old disk size; it restarts once.
                        guard !restarted else {
                            // A verdict, not a retry: restarting again on every start wouldn't help.
                            lastError = AgentInstaller.SSHError.commandFailed("Windows still sees the old disk size after restarting")
                            break
                        }
                        restarted = true
                        self.log.write("Windows is restarting to see the larger disk")
                        // Wait for the restart to actually begin (SSH goes away) before trying again:
                        // a slow guest can take minutes to get there.
                        for _ in 0..<60 {
                            guard self.state == .running, self.runGeneration == generation else { return }
                            do { _ = try await AgentInstaller.run(in: bundle, command: "echo up") } catch { break }
                            try? await Task.sleep(nanoseconds: 5_000_000_000)
                        }
                        continue
                    }
                    guard self.runGeneration == generation else { return } // the run ended while it ran
                    self.finishDiskGrow("guest partition extended: \(output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300))")
                    return
                } catch AgentInstaller.SSHError.commandFailed(let m) {
                    lastError = AgentInstaller.SSHError.commandFailed(m) // the script ran and said no
                    break
                } catch {
                    // Not reachable yet (no IP address, SSH not up, still booting): keep trying.
                    lastError = error
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
            guard let self, self.runGeneration == generation else { return }
            guard let failure = lastError as? AgentInstaller.SSHError, case .commandFailed = failure else {
                // Never got a verdict from the guest: keep the flag and try again next start.
                self.log.write("could not extend the guest partition yet (\(lastError?.localizedDescription ?? "VM stopped")); will retry on next start")
                return
            }
            self.finishDiskGrow("could not extend the guest partition (extend it in the guest): \(failure.localizedDescription)")
        }
    }

    private func finishDiskGrow(_ message: String) {
        var c = (try? bundle.loadConfig()) ?? config
        c.pendingDiskGrow = nil
        try? saveConfig(c)
        log.write(message)
    }

    /// Extends C: to the end of the disk. Windows Setup puts a small recovery (WinRE) partition
    /// behind C:; when that is what's in the way, WinRE is moved into C: (reagentc /disable copies
    /// it to \\Windows\\System32\\Recovery, /enable re-registers it there) and the partition removed —
    /// Microsoft's documented procedure for growing C:. Every step is checked; nothing is removed
    /// unless the WinRE image is safely on C:.
    static let restartMarker = "VITRINE-RESTARTING"

    /// `diskBytes`: the disk's new size. A Windows that "shut down" with Fast Startup on resumes
    /// its kernel from hibernation and still sees the old size; then it turns Fast Startup off and
    /// restarts once (printing `restartMarker`), and the host runs this again afterwards.
    static func windowsExtendScript(diskBytes: UInt64) -> String {
        """
        $ErrorActionPreference = 'Stop'
        $ProgressPreference = 'SilentlyContinue'
        Update-HostStorageCache
        $c = Get-Partition -DriveLetter C
        if ((Get-Disk -Number $c.DiskNumber).Size -lt \(diskBytes) - 64MB) {
          powercfg /h off
          shutdown /r /t 5 /c 'Vitrine: restarting to use the larger disk'
          if ($LASTEXITCODE -ne 0) { throw "shutdown /r failed ($LASTEXITCODE)" }
          '\(restartMarker)'
          exit 0
        }
        $max = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
        $after = @(Get-Partition -DiskNumber $c.DiskNumber | Where-Object { $_.Offset -gt $c.Offset } | Sort-Object Offset)
        $last = Get-Partition -DiskNumber $c.DiskNumber | Sort-Object Offset | Select-Object -Last 1
        $unallocated = (Get-Disk -Number $c.DiskNumber).Size - ($last.Offset + $last.Size)
        # The new space is behind the partition(s) that follow C: (Setup's WinRE): C: can't reach it.
        if ($after.Count -gt 0 -and $unallocated -gt 16MB) {
          $next = $after[0]
          if ($after.Count -gt 1 -or $next.Type -ne 'Recovery') { throw 'C: is followed by a partition that is not WinRE; extend it in Disk Management' }
          # Only Windows Setup's own WinRE partition is removed: it must be where WinRE is registered,
          # and small (vendor recovery partitions holding factory images are much larger).
          $info = (reagentc /info | Out-String)
          if ($info -notmatch ('harddisk' + $c.DiskNumber + '\\\\partition' + $next.PartitionNumber + '\\\\')) {
            throw 'the partition after C: is not the registered WinRE partition; extend C: by hand'
          }
          if ($next.Size -gt 2GB) { throw 'the recovery partition after C: is larger than WinRE needs; extend C: by hand' }
          reagentc /disable | Out-Null
          if ($LASTEXITCODE -ne 0) { throw "reagentc /disable failed ($LASTEXITCODE)" }
          if (-not (Test-Path -LiteralPath "$env:SystemRoot\\System32\\Recovery\\Winre.wim")) {
            reagentc /enable | Out-Null
            throw 'the WinRE image was not copied to C:; the recovery partition was kept'
          }
          $next | Remove-Partition -Confirm:$false
          reagentc /enable | Out-Null
          if ($LASTEXITCODE -ne 0) { 'warning: reagentc /enable failed; run it as administrator' }
          'moved WinRE into C:'
          $max = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
        }
        if ((Get-Partition -DriveLetter C).Size -lt $max - 1MB) { Resize-Partition -DriveLetter C -Size $max }
        $c = Get-Partition -DriveLetter C
        $size = $c.Size
        $last = Get-Partition -DiskNumber $c.DiskNumber | Sort-Object Offset | Select-Object -Last 1
        $unallocated = (Get-Disk -Number $c.DiskNumber).Size - ($last.Offset + $last.Size)
        # Done only when C: is as large as it can be and no new space is left unused at the end.
        if ($size -lt $max - 1MB -or $unallocated -gt 16MB) {
          throw ('C: did not grow (' + [math]::Round($size / 1GB, 1) + ' GB, ' + [math]::Round($unallocated / 1GB, 1) + ' GB unallocated)')
        }
        'C: ' + [math]::Round($size / 1GB, 1) + ' GB'
        """
    }

    /// cloud-init usually grows the root filesystem at boot already; this covers other setups and
    /// fails (non-zero) when it can't do the job, instead of reporting success.
    static let linuxExtendCommand = """
    set -e
    root=$(findmnt --nofsroot -no SOURCE /); fstype=$(findmnt -no FSTYPE /)
    case "$root" in /dev/mapper/*|/dev/dm-*) echo "the root filesystem is on LVM; extend it with lvextend" >&2; exit 1;; esac
    name=$(basename "$root")
    if [ -f "/sys/class/block/$name/partition" ]; then
      command -v growpart >/dev/null || { echo "growpart is not installed (cloud-guest-utils)" >&2; exit 1; }
      disk=$(lsblk -no PKNAME "$root")
      sudo -n growpart "/dev/$disk" "$(cat /sys/class/block/$name/partition)" || [ $? -eq 1 ]
      # NOCHANGE also means "another partition is in the way": check the partition reaches the end.
      end=$(( $(cat /sys/class/block/$name/start) + $(cat /sys/class/block/$name/size) ))
      if [ $(( $(cat /sys/class/block/$disk/size) - end )) -gt 32768 ]; then
        echo "the root partition can't reach the new space (another partition follows it)" >&2; exit 1
      fi
    elif [ ! -e "/sys/class/block/$name/device" ]; then
      echo "can't tell which disk holds the root filesystem ($root)" >&2; exit 1
    fi
    case "$fstype" in
      ext2|ext3|ext4) sudo -n resize2fs "$root" ;;
      xfs) sudo -n xfs_growfs / ;;
      btrfs) sudo -n btrfs filesystem resize max / ;;
      *) echo "can't grow a $fstype filesystem" >&2; exit 1 ;;
    esac
    df -h / | tail -1
    """
}
