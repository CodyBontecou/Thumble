$ErrorActionPreference = 'Stop'
$installer = Join-Path $env:RUNNER_TEMP 'ViGEmBus-1.22.0.exe'
Invoke-WebRequest 'https://github.com/nefarius/ViGEmBus/releases/download/v1.22.0/ViGEmBus_1.22.0_x64_x86_arm64.exe' -OutFile $installer
$expected = '89220a7865076b342892f98865f3499fb7c4cfd673159e89d352c360fd014c6a'
if ((Get-FileHash $installer -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) { throw 'Official driver installer hash mismatch' }
$signature = Get-AuthenticodeSignature $installer
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Nefarius') { throw 'Driver installer signature could not be verified' }
# Same unattended flags and SHA-256 as Microsoft's winget manifest for 1.22.0.
# Advanced Installer's external bootstrapper UI also needs /exenoui.
$process = Start-Process -FilePath $installer -ArgumentList '/exenoui','/qn','/norestart' -PassThru
if (-not $process.WaitForExit(180000)) { taskkill /PID $process.Id /T /F; throw 'Driver installer exceeded three minutes' }
$process.Refresh()
if ($process.ExitCode -notin @(0,3010)) { throw "Driver install failed with exit code $($process.ExitCode)" }
Write-Output "Verified and installed official ViGEmBus 1.22.0 (exit $($process.ExitCode)); native XInput verification follows."
Get-CimInstance Win32_SystemDriver | Where-Object { $_.Name -match 'ViGEm' } | Select-Object Name,State,StartMode,PathName | Format-List
# GitHub's Windows Server image lacks the inbox Xbox 360 function driver
# present on supported Windows 10/11 desktops. Stage Microsoft's signed package
# so ViGEm's Xbox child can actually start (upstream ViGEmBus issue #85).
# Microsoft Update Catalog update 31f327c0-b9b6-4829-afe4-7cbf52b3a384.
$xboxCab = Join-Path $env:RUNNER_TEMP 'microsoft-xbox360.cab'
$xboxFolder = Join-Path $env:RUNNER_TEMP 'microsoft-xbox360'
Invoke-WebRequest 'https://catalog.s.download.windowsupdate.com/msdownload/update/driver/drvs/2013/01/20289581_7385d6be1b053a35955a910f11436729a1d4cb56.cab' -OutFile $xboxCab
if ((Get-FileHash $xboxCab -Algorithm SHA256).Hash.ToLowerInvariant() -ne '49bd427e53f5c63a1a03b791cf6deeefe3a2ac5700dc4db5e39fad98f3070fa6') { throw 'Microsoft Xbox driver archive hash mismatch' }
New-Item -ItemType Directory -Path $xboxFolder -Force | Out-Null
& expand.exe $xboxCab '-F:*' $xboxFolder
if ($LASTEXITCODE -ne 0) { throw 'Microsoft Xbox driver archive extraction failed' }
$catalog = Get-AuthenticodeSignature (Join-Path $xboxFolder 'xusb21.cat')
if ($catalog.Status -ne 'Valid' -or $catalog.SignerCertificate.Subject -notmatch 'Microsoft') { throw 'Microsoft Xbox driver catalog signature could not be verified' }
& pnputil.exe /add-driver (Join-Path $xboxFolder 'xusb21.inf') /install
if ($LASTEXITCODE -notin @(0,3010)) { throw "Microsoft Xbox driver staging failed with exit code $LASTEXITCODE" }
$compiler = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
if (-not (Test-Path $compiler)) { choco install innosetup --no-progress -y; if ($LASTEXITCODE -ne 0) { throw 'Inno Setup installation failed' } }
