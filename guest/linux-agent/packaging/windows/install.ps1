#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Installs the Vitrine guest agent in a Windows 10/11 guest.

.DESCRIPTION
  Copies vitrine-agent.exe to "C:\Program Files\Vitrine", opens TCP 20819 in
  the firewall for it (the host reaches it through QEMU user-net hostfwd),
  registers a logon scheduled task so the agent runs in each user's
  interactive session (it must: capture, input and clipboard are per
  session), and starts it now.

.PARAMETER Exe
  Path to the agent build matching the guest CPU (vitrine-agent-windows-arm64.exe
  or vitrine-agent-windows-amd64.exe). Defaults to vitrine-agent.exe next to this
  script.

.PARAMETER Elevated
  Accepted for compatibility; the agent runs elevated by default.

.PARAMETER Limited
  Run the agent with a filtered (non-elevated) token. Its host channel, the
  virtio-serial port, is only open to administrators and SYSTEM, so a limited
  agent can't reach the host unless it is started with --tcp (less secure:
  guest programs can then reach that port too). The default, the user's full
  token, also lets it drive elevated windows (UIPI blocks input to them otherwise).

.PARAMETER CameraDll
  The camera media source matching the guest CPU (vitrine-camera-arm64.dll or
  vitrine-camera-amd64.dll). Defaults to the one for this machine next to this script.
  Installed as "C:\Program Files\Vitrine\vitrine-camera.dll" and registered machine-wide, it
  lets the agent create the "Vitrine Camera" virtual camera (Windows 11 only; skipped on
  older Windows).

.PARAMETER CameraOnly
  Install only the camera media source; leave the agent alone.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install.ps1 -Exe .\vitrine-agent-windows-arm64.exe

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install.ps1 -CameraOnly -CameraDll .\vitrine-camera-arm64.dll
#>
param(
    [string]$Exe = (Join-Path $PSScriptRoot 'vitrine-agent.exe'),
    [int]$Port = 20819,
    [switch]$Elevated,
    [switch]$Limited,
    [string]$CameraDll = '',
    [switch]$CameraOnly
)
$ErrorActionPreference = 'Stop'

$dir = Join-Path $env:ProgramFiles 'Vitrine'
# guest/windows-camera/common.h; the agent looks the source up under this CLSID.
$cameraClsid = '{E0945567-3221-4186-B6DE-EAE89A9A73E4}'

# The camera media source: the Frame Server loads it (as LocalService) for the virtual camera the
# agent creates with MFCreateVirtualCamera, which needs Windows 11 (build 22000).
function Install-Camera {
    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt 22000) {
        Write-Host "Camera: skipped (Windows build $build; virtual cameras need Windows 11)"
        return
    }
    $dll = $CameraDll
    if (-not $dll) {
        # The machine's native architecture (what the Frame Server runs as), even from an
        # emulated x64 PowerShell on ARM64.
        $arch = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment').PROCESSOR_ARCHITECTURE
        $name = if ($arch -eq 'ARM64') { 'vitrine-camera-arm64.dll' } else { 'vitrine-camera-amd64.dll' }
        $dll = Join-Path $PSScriptRoot $name
    }
    if (-not (Test-Path $dll)) {
        Write-Warning "Camera: $dll not found; the guest gets no virtual camera"
        return
    }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $target = Join-Path $dir 'vitrine-camera.dll'
    # The Frame Server keeps the old copy loaded while a camera app runs: a loaded DLL can't be
    # overwritten but can be renamed out of the way (and deleted on a later install).
    Get-ChildItem -Path $dir -Filter 'vitrine-camera.*.old' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    try {
        Copy-Item -Path $dll -Destination $target -Force
    } catch {
        Rename-Item -Path $target -NewName ('vitrine-camera.{0}.old' -f [DateTime]::Now.Ticks)
        Copy-Item -Path $dll -Destination $target -Force
    }
    # Machine-wide COM registration: LocalService doesn't see per-user (HKCU) classes.
    $key = "HKLM:\SOFTWARE\Classes\CLSID\$cameraClsid"
    New-Item -Path "$key\InprocServer32" -Force | Out-Null
    Set-ItemProperty -Path $key -Name '(default)' -Value 'Vitrine Camera'
    Set-ItemProperty -Path "$key\InprocServer32" -Name '(default)' -Value $target
    Set-ItemProperty -Path "$key\InprocServer32" -Name 'ThreadingModel' -Value 'Both'
    Write-Host "Camera: installed $target"
}

if ($CameraOnly) {
    Install-Camera
    return
}

if (-not (Test-Path $Exe)) { throw "Agent binary not found: $Exe" }

$target = Join-Path $dir 'vitrine-agent.exe'
$taskName = 'Vitrine Agent'
$ruleName = 'Vitrine guest agent'

# Stop a running copy so the file can be replaced.
Get-Process -Name 'vitrine-agent' -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500

New-Item -ItemType Directory -Force -Path $dir | Out-Null
Copy-Item -Path $Exe -Destination $target -Force
Write-Host "Installed $target"

# Firewall: allow the agent's listener on any profile (QEMU user-net is a
# "Public" network by default).
Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP `
    -LocalPort $Port -Program $target -Profile Any | Out-Null
Write-Host "Firewall rule '$ruleName' allows TCP $Port"

# Logon task for every member of BUILTIN\Users, in their interactive session.
$agentArgs = if ($Port -ne 20819) { "--tcp 0.0.0.0:$Port" } else { '' }
$action = if ($agentArgs) { New-ScheduledTaskAction -Execute $target -Argument $agentArgs } else { New-ScheduledTaskAction -Execute $target }
$trigger = New-ScheduledTaskTrigger -AtLogOn
$runLevel = if ($Limited) { 'Limited' } else { 'Highest' }
$principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel $runLevel
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Force | Out-Null
Write-Host "Scheduled task '$taskName' starts the agent at every logon"

# Camera support is optional: a failure here doesn't fail the agent install.
try { Install-Camera } catch { Write-Warning "Camera: not installed: $_" }

# Start it now in the logged-on session(s).
Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 2
if (Get-Process -Name 'vitrine-agent' -ErrorAction SilentlyContinue) {
    Write-Host "vitrine-agent is running; log: %LOCALAPPDATA%\Vitrine\vitrine-agent.log"
} else {
    Write-Warning "vitrine-agent did not start yet; it will start at the next logon."
}
