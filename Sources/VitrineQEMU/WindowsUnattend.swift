import Foundation
import VitrineCore

/// Unattended Windows 11 setup: an `autounattend.xml` on a seed ISO
/// partitions the disk, installs the chosen edition, creates the local account, skips OOBE, signs in
/// automatically and runs first-logon commands (OpenSSH server, firewall rule for the Vitrine agent,
/// virtio drivers from the seed). Windows Setup picks the file up from the root of any attached disc.
public enum WindowsUnattend {
    public struct Options: Sendable {
        public var architecture: VMConfig.Architecture
        public var computerName: String
        public var fullName: String
        public var username: String
        public var password: String
        public var edition: String = "Windows 11 Pro"
        public var locale: String = "en-US"
        /// Windows time zone ID; defaults to the Mac's zone (QEMU gives Windows a local-time RTC).
        public var timeZone: String = WindowsTimeZone.current
        /// Skip OOBE's screens entirely (deprecated switches that Windows 11 still honours). For the
        /// emulated x64 guest, whose user OOBE is slow enough that Windows' OOBE watchdog declares it
        /// hung, reboots and asks for a network to fetch a fix ("Why did my PC restart?").
        public var skipOOBE = false
        public init(architecture: VMConfig.Architecture, computerName: String, fullName: String,
                    username: String, password: String) {
            self.architecture = architecture; self.computerName = computerName
            self.fullName = fullName; self.username = username; self.password = password
        }
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// NetBIOS-safe computer name (≤15 chars, letters/digits/hyphen).
    public static func computerName(forVMName name: String) -> String {
        let s = String(name.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return s.isEmpty ? "VITRINE-VM" : String(s.prefix(15))
    }

    public static func xml(_ o: Options) -> String {
        let arch = o.architecture == .aarch64 ? "arm64" : "amd64"
        let e = xmlEscape
        func component(_ name: String, _ body: String) -> String {
            """
                    <component name="\(name)" processorArchitecture="\(arch)" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            \(body)
                    </component>
            """
        }
        // Commands run once at first sign-in. Drivers come from the seed disc (any drive letter).
        let firstLogon: [String] = [
            #"cmd /c for %d in (D E F G H I) do if exist %d:\vitrine\setup.cmd call %d:\vitrine\setup.cmd"#,
        ]
        let logonXML = firstLogon.enumerated().map { i, cmd in
            """
                            <SynchronousCommand wcm:action="add">
                                <Order>\(i + 1)</Order>
                                <CommandLine>\(e(cmd))</CommandLine>
                            </SynchronousCommand>
            """
        }.joined(separator: "\n")

        let skipOOBEXML = """
                                    <SkipMachineOOBE>true</SkipMachineOOBE>
                                    <SkipUserOOBE>true</SkipUserOOBE>
        """
        // QEMU's stock EDK2 builds ship without Microsoft's Secure Boot keys enrolled, so Setup's
        // hardware check would refuse the VM. Microsoft's documented LabConfig switches skip it.
        // (The TPM is real — swtpm — but its check is bypassed too in case swtpm is unavailable.)
        var commands = ["BypassSecureBootCheck", "BypassTPMCheck"].map {
            "reg add HKLM\\SYSTEM\\Setup\\LabConfig /v \($0) /t REG_DWORD /d 1 /f"
        }
        // The installer disc sits on virtio-scsi (fast), which WinPE has no inbox driver for; Setup
        // looks for its media before applying DriverPaths, so load vioscsi from the seed disc first.
        // The seed's drive letter varies, hence the loop.
        commands.insert(#"cmd /c for %d in (C D E F G H I J) do if exist %d:\winpe\vioscsi\vioscsi.inf drvload %d:\winpe\vioscsi\vioscsi.inf"#, at: 0)
        let labConfig = commands.enumerated().map { i, command in
            """
                            <RunSynchronousCommand wcm:action="add"><Order>\(i + 1)</Order><Path>\(e(command))</Path></RunSynchronousCommand>
            """
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend">
            <settings pass="windowsPE">
        \(component("Microsoft-Windows-International-Core-WinPE", """
                        <SetupUILanguage><UILanguage>\(e(o.locale))</UILanguage></SetupUILanguage>
                        <InputLocale>\(e(o.locale))</InputLocale>
                        <SystemLocale>\(e(o.locale))</SystemLocale>
                        <UILanguage>\(e(o.locale))</UILanguage>
                        <UserLocale>\(e(o.locale))</UserLocale>
        """))
        \(component("Microsoft-Windows-PnpCustomizationsWinPE", """
                        <DriverPaths>
                            <PathAndCredentials wcm:action="add" wcm:keyValue="1"><Path>D:\\drivers</Path></PathAndCredentials>
                            <PathAndCredentials wcm:action="add" wcm:keyValue="2"><Path>E:\\drivers</Path></PathAndCredentials>
                            <PathAndCredentials wcm:action="add" wcm:keyValue="3"><Path>F:\\drivers</Path></PathAndCredentials>
                        </DriverPaths>
        """))
        \(component("Microsoft-Windows-Setup", """
                        <RunSynchronous>
        \(labConfig)
                        </RunSynchronous>
                        <DiskConfiguration>
                            <Disk wcm:action="add">
                                <DiskID>0</DiskID>
                                <WillWipeDisk>true</WillWipeDisk>
                                <CreatePartitions>
                                    <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition>
                                    <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
                                    <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
                                </CreatePartitions>
                                <ModifyPartitions>
                                    <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
                                    <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
                                    <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
                                </ModifyPartitions>
                            </Disk>
                        </DiskConfiguration>
                        <ImageInstall>
                            <OSImage>
                                <InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/NAME</Key><Value>\(e(o.edition))</Value></MetaData></InstallFrom>
                                <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
                            </OSImage>
                        </ImageInstall>
                        <UserData>
                            <AcceptEula>true</AcceptEula>
                            <FullName>\(e(o.fullName))</FullName>
                            <ProductKey><Key></Key><WillShowUI>OnError</WillShowUI></ProductKey>
                        </UserData>
        """))
            </settings>
            <settings pass="specialize">
        \(component("Microsoft-Windows-Shell-Setup", """
                        <ComputerName>\(e(o.computerName))</ComputerName>
                        <TimeZone>\(e(o.timeZone))</TimeZone>
        """))
        \(component("Microsoft-Windows-Deployment", """
                        <RunSynchronous>
                            <RunSynchronousCommand wcm:action="add">
                                <Order>1</Order>
                                <Path>reg add HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path>
                            </RunSynchronousCommand>
                        </RunSynchronous>
        """))
            </settings>
            <settings pass="oobeSystem">
        \(component("Microsoft-Windows-International-Core", """
                        <InputLocale>\(e(o.locale))</InputLocale>
                        <SystemLocale>\(e(o.locale))</SystemLocale>
                        <UILanguage>\(e(o.locale))</UILanguage>
                        <UserLocale>\(e(o.locale))</UserLocale>
        """))
        \(component("Microsoft-Windows-Shell-Setup", """
                        <OOBE>
                            <HideEULAPage>true</HideEULAPage>
                            <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                            <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                            <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                            <ProtectYourPC>3</ProtectYourPC>
        \(o.skipOOBE ? skipOOBEXML : "")
                        </OOBE>
                        <UserAccounts>
                            <LocalAccounts>
                                <LocalAccount wcm:action="add">
                                    <Name>\(e(o.username))</Name>
                                    <DisplayName>\(e(o.fullName))</DisplayName>
                                    <Group>Administrators</Group>
                                    <Password><Value>\(PasswordHash.unattendObfuscated(o.password))</Value><PlainText>false</PlainText></Password>
                                </LocalAccount>
                            </LocalAccounts>
                        </UserAccounts>
                        <AutoLogon>
                            <Enabled>true</Enabled>
                            <Username>\(e(o.username))</Username>
                            <Password><Value>\(PasswordHash.unattendObfuscated(o.password))</Value><PlainText>false</PlainText></Password>
                            <LogonCount>9999999</LogonCount>
                        </AutoLogon>
                        <FirstLogonCommands>
        \(logonXML)
                        </FirstLogonCommands>
        """))
            </settings>
        </unattend>

        """
    }

    /// MSI OpenSSH can start sshd without its directory in the service's PATH. Resolve the
    /// default relative SFTP subsystem against the actual service executable before uploads.
    public static let openSSHSetupScript = #"""
    $ErrorActionPreference = 'Stop'
    Set-Service sshd -StartupType Automatic
    Start-Service sshd
    $command = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\sshd').ImagePath
    $sshd = if ($command -match '^"([^"]+)"') { $Matches[1] } else { ($command -split '\s+')[0] }
    $sftp = Join-Path (Split-Path $sshd) 'sftp-server.exe'
    if (!(Test-Path -LiteralPath $sftp)) { throw 'OpenSSH SFTP server is missing' }
    $config = Join-Path $env:ProgramData 'ssh\sshd_config'
    $before = [IO.File]::ReadAllBytes($config)
    $text = [IO.File]::ReadAllText($config)
    $pattern = '(?im)^([ \t]*Subsystem[ \t]+sftp[ \t]+)sftp-server(?:\.exe)?(?=[ \t\r\n]|$)'
    $updated = [regex]::Replace($text, $pattern, { param($m) $m.Groups[1].Value + '"' + $sftp.Replace('\', '/') + '"' })
    if ($updated -cne $text) {
        try {
            [IO.File]::WriteAllText($config, $updated, (New-Object Text.UTF8Encoding($false)))
            & $sshd -t
            if ($LASTEXITCODE -ne 0) { throw 'OpenSSH configuration validation failed' }
        } catch {
            [IO.File]::WriteAllBytes($config, $before)
            throw
        }
        Restart-Service sshd
    }
    """#

    /// First-logon script placed at \vitrine\setup.cmd on the seed disc.
    public static let setupScript = #"""
    @echo off
    rem Vitrine first-logon setup: drivers, OpenSSH server (for agent installation), agent firewall rule.
    rem Full path of the seed disc's root: msiexec refuses package paths containing ".." (1619).
    for %%I in ("%~dp0..") do set "SEED=%%~fI"
    if "%SEED:~-1%"=="\" set "SEED=%SEED:~0,-1%"
    pnputil /add-driver "%SEED%\drivers\*.inf" /subdirs /install
    rem OpenSSH from the seed disc when it's there (seconds); otherwise Windows' Feature on Demand,
    rem which comes from Windows Update (minutes natively, hours in an emulated x64 guest).
    rem msiexec succeeds with 0 or 3010 (reboot pending); it fails while another installation runs
    rem (Windows' own first-boot work), so it gets a second try before falling back.
    if not exist "%SEED%\vitrine\openssh.msi" goto ssh_fod
    msiexec /i "%SEED%\vitrine\openssh.msi" /qn /norestart ADDLOCAL=Server
    if %errorlevel% equ 0 goto ssh_start
    if %errorlevel% equ 3010 goto ssh_start
    timeout /t 30 /nobreak >nul
    msiexec /i "%SEED%\vitrine\openssh.msi" /qn /norestart ADDLOCAL=Server
    if %errorlevel% equ 0 goto ssh_start
    if %errorlevel% equ 3010 goto ssh_start
    echo Vitrine: OpenSSH MSI failed (%errorlevel%), trying Windows Update >> "%SystemRoot%\Temp\vitrine-setup.log"
    :ssh_fod
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0"
    :ssh_start
    powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand __VITRINE_OPENSSH_SETUP__
    if errorlevel 1 echo Vitrine: the OpenSSH server did not start >> "%SystemRoot%\Temp\vitrine-setup.log"
    netsh advfirewall firewall add rule name="Vitrine Agent" dir=in action=allow protocol=TCP localport=20819
    netsh advfirewall firewall add rule name="OpenSSH Server" dir=in action=allow protocol=TCP localport=22
    rem The agent runs elevated; share drives it maps must also show up in (non-elevated) Explorer.
    reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v EnableLinkedConnections /t REG_DWORD /d 1 /f
    rem A VM's "display" should never blank or sleep on its own; the host suspends it instead.
    powercfg /change monitor-timeout-ac 0
    powercfg /change standby-timeout-ac 0
    powercfg /change hibernate-timeout-ac 0
    rem No hibernation or Fast Startup: "shut down" must really shut down, or Windows keeps its old
    rem view of the hardware (a grown disk stays at its old size) and hiberfil.sys wastes disk space.
    powercfg /h off
    if exist "%SEED%\vitrine\agent\vitrine-agent.exe" (
      mkdir "%ProgramFiles%\Vitrine" 2>nul
      copy /y "%SEED%\vitrine\agent\vitrine-agent.exe" "%ProgramFiles%\Vitrine\vitrine-agent.exe"
      schtasks /create /tn "Vitrine Agent" /tr "\"%ProgramFiles%\Vitrine\vitrine-agent.exe\"" /sc onlogon /rl highest /f
      start "" "%ProgramFiles%\Vitrine\vitrine-agent.exe"
    )
    rem Power off: Vitrine sees setup is done, ejects the installer/seed media (the seed holds the
    rem password) and boots straight back into the desktop on the virtio-gpu display.
    shutdown /s /t 15 /c "Vitrine is finishing setup"
    """#.replacingOccurrences(of: "__VITRINE_OPENSSH_SETUP__", with: openSSHSetupScript.data(using: .utf16LittleEndian)!.base64EncodedString())

    /// Builds the seed ISO: autounattend.xml, vitrine\setup.cmd, optional drivers\ and agent.
    public static func makeSeedISO(at url: URL, options: Options, driversDirectory: URL?, agentExecutable: URL?,
                                   openSSHInstaller: URL? = nil) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent().appendingPathComponent(".winseed-\(UUID().uuidString)")
        try fm.createDirectory(at: dir.appendingPathComponent("vitrine/agent"), withIntermediateDirectories: true)
        defer { try? fm.removeItemForcibly(at: dir) }
        try xml(options).write(to: dir.appendingPathComponent("autounattend.xml"), atomically: true, encoding: .utf8)
        try setupScript.replacingOccurrences(of: "\n", with: "\r\n")
            .write(to: dir.appendingPathComponent("vitrine/setup.cmd"), atomically: true, encoding: .utf8)
        if let driversDirectory {
            try fm.copyItem(at: driversDirectory, to: dir.appendingPathComponent("drivers"))
            // vioscsi is loaded by hand in WinPE (drvload, see the windowsPE RunSynchronous) and must
            // not also be offered through DriverPaths: Setup then fails with 0x80070103 - 0x40031.
            let scsi = dir.appendingPathComponent("drivers/vioscsi")
            if fm.fileExists(atPath: scsi.path) {
                try fm.createDirectory(at: dir.appendingPathComponent("winpe"), withIntermediateDirectories: true)
                try fm.moveItem(at: scsi, to: dir.appendingPathComponent("winpe/vioscsi"))
            }
        }
        if let agentExecutable {
            try fm.copyItem(at: agentExecutable, to: dir.appendingPathComponent("vitrine/agent/vitrine-agent.exe"))
        }
        if let openSSHInstaller {
            try fm.copyItem(at: openSSHInstaller, to: dir.appendingPathComponent("vitrine/openssh.msi"))
        }
        try? fm.removeItem(at: url)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["makehybrid", "-quiet", "-iso", "-joliet", "-udf", "-default-volume-name", "VITRINE", "-o", url.path, dir.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw VitrineError.io("hdiutil could not build the Windows seed disc") }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) // contains the password
    }
}
