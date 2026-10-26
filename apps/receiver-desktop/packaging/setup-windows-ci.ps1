$ErrorActionPreference = 'Stop'
$installer = Join-Path $env:RUNNER_TEMP 'ViGEmBus-1.22.0.exe'
Invoke-WebRequest 'https://github.com/nefarius/ViGEmBus/releases/download/v1.22.0/ViGEmBus_1.22.0_x64_x86_arm64.exe' -OutFile $installer
$expected = '89220a7865076b342892f98865f3499fb7c4cfd673159e89d352c360fd014c6a'
if ((Get-FileHash $installer -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) { throw 'Official driver installer hash mismatch' }
$signature = Get-AuthenticodeSignature $installer
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Nefarius') { throw 'Driver installer signature could not be verified' }
$process = Start-Process -FilePath $installer -ArgumentList '/install','/quiet','/norestart' -Wait -PassThru
if ($process.ExitCode -notin @(0,3010)) { throw "Driver install failed with exit code $($process.ExitCode)" }
Write-Output "Verified and installed official ViGEmBus 1.22.0 (exit $($process.ExitCode)); native XInput verification follows."
$compiler = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
if (-not (Test-Path $compiler)) { choco install innosetup --no-progress -y; if ($LASTEXITCODE -ne 0) { throw 'Inno Setup installation failed' } }
