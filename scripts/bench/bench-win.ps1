$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Continue'
$z = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
# Same 7-Zip release as the other systems (26.04).
if (-not ((& $z 2>&1 | Out-String) -match ' 26\.04 ')) {
  $exe = Join-Path $env:TEMP '7z-setup.exe'
  Invoke-WebRequest -UseBasicParsing 'https://www.7-zip.org/a/7z2604-arm64.exe' -OutFile $exe
  Start-Process $exe -ArgumentList '/S' -Wait
}
"sevenzip=" + ([regex]'7-Zip [0-9.]+').Match((& $z 2>&1 | Out-String)).Value
function Tot($out) { (($out | Select-String '^Tot:').Line -split '\s+')[3] }
"cpu_1t_mips=" + (Tot (& $z b -mmt1))
"cpu_4t_mips=" + (Tot (& $z b -mmt4))
"cpu_mt_mips=" + (Tot (& $z b))
"threads=$env:NUMBER_OF_PROCESSORS"
# x64 apps on Windows on Arm run under Prism emulation: same 7-Zip release, x64 build.
$zx = 'C:\7zip-x64\7z.exe'
if (-not (Test-Path $zx)) {
  $exe = Join-Path $env:TEMP '7z-x64-setup.exe'
  Invoke-WebRequest -UseBasicParsing 'https://www.7-zip.org/a/7z2604-x64.exe' -OutFile $exe
  Start-Process $exe -ArgumentList '/S', '/D=C:\7zip-x64' -Wait
}
"x64_cpu_1t_mips=" + (Tot (& $zx b -mmt1))
"x64_cpu_4t_mips=" + (Tot (& $zx b -mmt4))
# Disk: Microsoft DiskSpd, unbuffered (-Sh), 1 GiB test file.
$ds = Join-Path $env:TEMP 'diskspd\arm64\diskspd.exe'
if (-not (Test-Path $ds)) {
  $zip = Join-Path $env:TEMP 'diskspd.zip'
  Invoke-WebRequest -UseBasicParsing 'https://github.com/microsoft/diskspd/releases/latest/download/DiskSpd.zip' -OutFile $zip
  Expand-Archive -Force $zip (Join-Path $env:TEMP 'diskspd')
}
$f = 'C:\Users\Public\vitrine-bench.dat'
function Total($out, $col) { $l = ($out | Select-String '^total:' | Select-Object -First 1).Line; ($l -split '\|')[$col].Trim() }
$w = & $ds -c1G -b1M -d10 -o4 -t1 -w100 -Sh $f
$r = & $ds -c1G -b1M -d10 -o4 -t1 -w0 -Sh $f
$rr = & $ds -c1G -b4K -d10 -o32 -t4 -r -w0 -Sh $f
"disk_seq_write_mibs=" + (Total $w 2)
"disk_seq_read_mibs=" + (Total $r 2)
"disk_rand4k_read_iops=" + (Total $rr 3)
Remove-Item $f -ErrorAction SilentlyContinue
