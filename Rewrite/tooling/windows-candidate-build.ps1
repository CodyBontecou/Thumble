# Build-only experiment. Never execute anything compiled by this script.
[CmdletBinding()]
param(
    [ValidateSet('Plan', 'ValidateOnly', 'Build')][string]$Mode = 'Plan',
    [string]$SourceRoot,
    [string]$WorkRoot,
    [string]$EvidenceRoot,
    [switch]$ConfirmUnsignedCompileOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$pin = Get-Content -Raw (Join-Path $PSScriptRoot 'windows-candidate-toolchain.json') | ConvertFrom-Json
if ($pin.version -ne 1 -or $pin.architecture -ne 'x64') { throw 'Unsupported manifest' }
if ($Mode -eq 'Plan') {
    [ordered]@{ mode = 'plan'; source = $pin.upstream; packages = $pin.packages;
        architecture = $pin.architecture; actions = @('verify pristine pinned source', 'verify package SHA512 before extraction', 'assemble kit', 'compile two audited native entrypoints', 'assert unsigned outputs', 'emit hashes only');
        install = $false; sign = $false; load = $false; probe = $false; redistributeBinaries = $false } | ConvertTo-Json -Depth 8
    return
}
function Assert-Source {
    $head = & git -C $SourceRoot rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $head -cne $pin.upstream.commit) { throw 'Source commit mismatch' }
    $dirty = & git -C $SourceRoot status --porcelain --untracked-files=all
    if ($LASTEXITCODE -ne 0 -or $dirty) { throw 'Source must be pristine' }
    foreach ($entry in $pin.upstream.auditedFiles.PSObject.Properties) {
        $path = Join-Path $SourceRoot $entry.Name
        if ((Get-FileHash -Algorithm SHA256 $path).Hash.ToLowerInvariant() -cne $entry.Value) { throw "Audited source hash mismatch: $($entry.Name)" }
    }
}
if (-not $SourceRoot -or -not (Test-Path -LiteralPath $SourceRoot -PathType Container)) { throw 'Existing pinned source checkout required' }
$SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
Assert-Source
if ($Mode -eq 'ValidateOnly') {
    @{ mode = 'validated-source-only'; commit = $pin.upstream.commit; compiled = $false; packagesDownloaded = $false } | ConvertTo-Json
    return
}
if (-not $IsWindows -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64' -or -not $ConfirmUnsignedCompileOnly) { throw 'Build requires Windows and explicit unsigned compile-only switch' }
if (-not $WorkRoot -or -not $EvidenceRoot) { throw 'New separate WorkRoot and EvidenceRoot required' }
# Upstream cmd uses delayed expansion; reject shell metacharacters in caller paths.
foreach ($path in @($SourceRoot, $WorkRoot, $EvidenceRoot)) {
    if ($path -match '[!%&|<>^"\r\n]') { throw 'Unsupported shell metacharacter in path' }
}
$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)
$EvidenceRoot = [IO.Path]::GetFullPath($EvidenceRoot)
$sourcePrefix = $SourceRoot.TrimEnd('\') + '\'
if ($WorkRoot.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase) -or $EvidenceRoot.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase) -or $WorkRoot -eq $EvidenceRoot -or $WorkRoot.StartsWith($EvidenceRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or $EvidenceRoot.StartsWith($WorkRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Output directories must be separate from source and each other' }
foreach ($path in @($WorkRoot, $EvidenceRoot)) {
    if (Test-Path -LiteralPath $path) { throw 'Output directory must not exist' }
    New-Item -ItemType Directory -Path $path | Out-Null
}
if (Test-Path (Join-Path $SourceRoot 'build')) { throw 'Source build directory must not exist' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$packageEvidence = @()
foreach ($package in $pin.packages) {
    $archive = Join-Path $WorkRoot ($package.id + '.nupkg')
    Invoke-WebRequest -Uri $package.url -OutFile $archive
    if ((Get-Item $archive).Length -ne $package.bytes) { throw 'Package length mismatch' }
    $algorithm = $null
    $stream = [IO.File]::OpenRead($archive)
    try { $algorithm = [Security.Cryptography.SHA512]::Create(); $digest = [Convert]::ToBase64String($algorithm.ComputeHash($stream)) }
    finally { $stream.Dispose(); if ($algorithm) { $algorithm.Dispose() } }
    if ($digest -cne $package.sha512Base64) { throw 'Package SHA512 mismatch' }
    $destination = Join-Path $WorkRoot $package.id
    New-Item -ItemType Directory -Path $destination | Out-Null
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        if ($zip.Entries.Count -gt 100000) { throw 'Package entry limit' }
        $expandedBytes = [long]0
        foreach ($entry in $zip.Entries) {
            $expandedBytes += $entry.Length
            if ($expandedBytes -gt 4GB) { throw 'Package expansion limit' }
            $target = [IO.Path]::GetFullPath((Join-Path $destination $entry.FullName))
            if (-not $target.StartsWith($destination + '\', [StringComparison]::OrdinalIgnoreCase) -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw 'Unsafe archive entry' }
        }
    } finally { $zip.Dispose() }
    [IO.Compression.ZipFile]::ExtractToDirectory($archive, $destination)
    $packageEvidence += @{ id = $package.id; version = $pin.packageVersion; sha512Base64 = $digest; bytes = $package.bytes }
}
$kit = Join-Path $WorkRoot 'kit'
New-Item -ItemType Directory -Path $kit | Out-Null
Copy-Item (Join-Path $WorkRoot 'microsoft.windows.sdk.cpp/c/*') $kit -Recurse
$um = Join-Path $kit "Lib/$($pin.kitVersion)/um/x64"
New-Item -ItemType Directory -Path $um -Force | Out-Null
Copy-Item (Join-Path $WorkRoot 'microsoft.windows.sdk.cpp.x64/c/um/x64/*') $um -Recurse
$env:HM_SDK_ROOT = $kit
$env:HM_WDK_ROOT = Join-Path $WorkRoot 'microsoft.windows.wdk.x64/c'
$env:HM_WDK_VERSION = $pin.kitVersion
# Clear external build overrides; native_env selects the explicit x64 Visual Studio below.
foreach ($name in @('HM_STAMP_TIME', 'HM_ARM64_COMPILER_DIR', 'HM_ARM64_CRT_DIR', 'CL', '_CL_', 'LINK', '_LINK_')) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $vs -or @($vs).Count -ne 1) { throw 'Unique C++ Visual Studio installation required' }
if ($vs -match '[!%&|<>^"\r\n]') { throw 'Unsupported shell metacharacter in Visual Studio path' }
$env:VSINSTALLDIR = $vs
$vcvars = Join-Path $vs 'VC/Auxiliary/Build/vcvarsall.bat'
# Avoid PowerShell's legacy cmd.exe nested-quote rewriting: /c starts with
# the literal CALL token, and the generated wrapper owns all batch quoting.
function Invoke-BatchWrapper([string]$Wrapper, [string]$Log, [long]$Limit) {
    & $env:ComSpec /d /c call $Wrapper 2>&1 | Out-File $Log
    $code = $LASTEXITCODE
    if ((Get-Item $Log).Length -gt $Limit) {
        $file = [IO.File]::OpenWrite($Log); try { $file.SetLength($Limit) } finally { $file.Dispose() }
        throw 'Compile evidence log limit'
    }
    return $code
}
# Explicit initialization plus a compiler lookup is required before either
# build, not merely a successful native_env return. No compiled output runs.
$setup = @('@echo off', ('call "' + $vcvars + '" x64'), 'if errorlevel 1 exit /b 1', 'where cl.exe', 'if errorlevel 1 exit /b 1')
$compilerWrapper = Join-Path $WorkRoot 'compiler-metadata.cmd'
($setup + @('cl.exe /Bv', 'set VCToolsVersion', 'set VCToolsInstallDir', 'set UniversalCRTSdkDir', 'set UCRTVersion', 'exit /b 0')) | Set-Content -Encoding ascii $compilerWrapper
$compilerLog = Join-Path $EvidenceRoot 'compiler.txt'
# cl /Bv without input can return nonzero; wrapper records environment then exits.
if ((Invoke-BatchWrapper $compilerWrapper $compilerLog 128KB) -ne 0) { throw 'Compiler environment unavailable; inspect compiler.txt' }
Assert-Source
$buildLogs = @()
foreach ($entrypoint in @('build.cmd', 'build_companion.cmd')) {
    Assert-Source
    $log = Join-Path $EvidenceRoot ($entrypoint + '.log')
    $script = Join-Path $SourceRoot "scripts/$entrypoint"
    $wrapper = Join-Path $WorkRoot ($entrypoint + '-wrapper.cmd')
    ($setup + @(('call "' + $script + '" x64'), 'exit /b %errorlevel%')) | Set-Content -Encoding ascii $wrapper
    if ((Invoke-BatchWrapper $wrapper $log 2MB) -ne 0) { throw "Unsigned native compile failed: $entrypoint" }
    $buildLogs += $entrypoint + '.log'
}
$outputRoot = Join-Path $SourceRoot 'build'
$forbidden = Get-ChildItem $outputRoot -Recurse -File | Where-Object { $_.Extension -in @('.cat', '.cer', '.cert', '.pfx', '.p12', '.pem', '.key', '.crt', '.der', '.p7b', '.p7c', '.p7s', '.snk', '.pvk', '.spc') }
if ($forbidden) { throw 'Unexpected catalog/certificate/key in build output' }
$outputs = @()
foreach ($name in $pin.expectedOutputs) {
    $file = Join-Path $outputRoot $name
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing expected output: $name" }
    $status = 'not-applicable'
    if ([IO.Path]::GetExtension($file) -in @('.dll', '.exe')) {
        $status = (Get-AuthenticodeSignature -LiteralPath $file).Status.ToString()
        if ($status -ne 'NotSigned') { throw "Expected unsigned PE: $name" }
    }
    $outputs += @{ name = $name; bytes = (Get-Item $file).Length; sha256 = (Get-FileHash -Algorithm SHA256 $file).Hash.ToLowerInvariant(); authenticode = $status }
}
$licenses = @()
foreach ($package in $pin.packages) {
    $licenses += Get-ChildItem (Join-Path $WorkRoot $package.id) -Recurse -File | Where-Object { $_.Name -match '^(LICENSE|License|license|EULA)' } | ForEach-Object {
        @{ package = $package.id; name = $_.Name; sha256 = (Get-FileHash -Algorithm SHA256 $_.FullName).Hash.ToLowerInvariant() }
    }
}
if (@($licenses).Count -gt 128) { throw 'License metadata bound' }
# Only this evidence directory may be uploaded. Binaries/toolchain/source stay elsewhere.
[ordered]@{ version = 1; kind = 'unsigned-native-compile-feasibility'; upstreamCommit = $pin.upstream.commit;
    sourceHashes = $pin.upstream.auditedFiles; packages = $packageEvidence; outputs = $outputs; licenses = $licenses; logs = $buildLogs;
    compilerMetadata = 'compiler.txt'; msvcAndCrtPinned = $false; installed = $false; signed = $false;
    loaded = $false; sdkConstructed = $false; controllerCreated = $false; gameplayVerified = $false;
    licenseClearance = 'not-established; WDK package includes pre-release license terms' } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $EvidenceRoot 'manifest.json')
Copy-Item (Join-Path $SourceRoot 'LICENSE') (Join-Path $EvidenceRoot 'upstream-MIT-LICENSE.txt')
Copy-Item (Join-Path $SourceRoot 'sdk/HIDMaestro.Core/THIRD-PARTY-NOTICES.txt') (Join-Path $EvidenceRoot 'upstream-SDK-THIRD-PARTY-NOTICES.txt')
