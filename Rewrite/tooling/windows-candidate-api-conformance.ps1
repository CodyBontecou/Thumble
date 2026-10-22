# Data-only API subset, never the official SDK project or any device-capable type.
[CmdletBinding()]
param([ValidateSet('Plan','ValidateOnly','Run')][string]$Mode='Plan',[string]$SourceRoot,[string]$WorkRoot,[string]$EvidenceRoot,[switch]$ConfirmDataOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$project=Join-Path $PSScriptRoot '../native/windows-sdk-conformance'
$project=(Resolve-Path $project).Path
$pin=Get-Content -Raw (Join-Path $project 'pin.json') | ConvertFrom-Json
if ($Mode -eq 'Plan') { @{scope=$pin.assemblyScope;commit=$pin.commit;sdk=$pin.sdkVersion;declarations=$pin.declarations;officialSdkBuilt=$false;upstreamTargetsExecuted=$false;deviceTypesCompiled=$false;sign=$false;install=$false;probe=$false} | ConvertTo-Json;return }
if (-not $SourceRoot -or -not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {throw 'Pinned upstream checkout required'}
$SourceRoot=(Resolve-Path -LiteralPath $SourceRoot).Path
$head=& git -C $SourceRoot rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $head -cne $pin.commit) {throw 'Upstream commit mismatch'}
$dirty=& git -C $SourceRoot status --porcelain --untracked-files=all
if ($LASTEXITCODE -ne 0 -or $dirty) {throw 'Upstream source must be pristine'}
foreach ($file in $pin.files.PSObject.Properties) {if ((Get-FileHash -Algorithm SHA256 (Join-Path $SourceRoot $file.Name)).Hash.ToLowerInvariant() -cne $file.Value) {throw 'Pinned input hash mismatch'}}
if ($Mode -eq 'ValidateOnly') { @{sourceVerified=$true;compiled=$false;scope=$pin.assemblyScope} | ConvertTo-Json;return }
if (-not $ConfirmDataOnly -or -not $WorkRoot -or -not $EvidenceRoot) {throw 'Explicit data-only confirmation and new output directories required'}
$WorkRoot=[IO.Path]::GetFullPath($WorkRoot);$EvidenceRoot=[IO.Path]::GetFullPath($EvidenceRoot)
foreach ($path in @($WorkRoot,$EvidenceRoot,$SourceRoot,$project)) {if ($path -match '[;\r\n]') {throw 'Unsupported build property path'}}
$comparison=if ($IsWindows) {[StringComparison]::OrdinalIgnoreCase} else {[StringComparison]::Ordinal}
$separator=[IO.Path]::DirectorySeparatorChar
foreach ($pair in @(@($WorkRoot,$SourceRoot),@($EvidenceRoot,$SourceRoot),@($WorkRoot,$project),@($EvidenceRoot,$project),@($WorkRoot,$EvidenceRoot),@($EvidenceRoot,$WorkRoot))) {
    if ($pair[0].Equals($pair[1],$comparison) -or $pair[0].StartsWith($pair[1].TrimEnd($separator)+$separator,$comparison)) {throw 'Output directories must be separate from source/project and each other'}
}
foreach ($path in @($WorkRoot,$EvidenceRoot)) {if (Test-Path -LiteralPath $path) {throw 'Output directory must not exist'};New-Item -ItemType Directory -Path $path | Out-Null}
$env:DOTNET_CLI_HOME=Join-Path $WorkRoot 'dotnet-home'
$env:DOTNET_CLI_TELEMETRY_OPTOUT='1';$env:DOTNET_NOLOGO='1';$env:DOTNET_GENERATE_ASPNET_CERTIFICATE='false';$env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH='false'
$env:MSBuildUserExtensionsPath=Join-Path $WorkRoot 'empty-user-extensions'
function Invoke-Bounded([string]$Executable,[string[]]$Arguments,[string]$Log) {
    & $Executable @Arguments 2>&1 | Out-File -Encoding utf8 $Log
    $code=$LASTEXITCODE
    if ((Get-Item $Log).Length -gt 256KB) {$stream=[IO.File]::OpenWrite($Log);try {$stream.SetLength(256KB)} finally {$stream.Dispose()};throw 'Conformance log limit'}
    if ($code -ne 0) {throw 'Data API conformance command failed; inspect bounded log'}
}
Push-Location $project
try {
    $version=& dotnet --version
    if ($LASTEXITCODE -ne 0 -or $version -cne $pin.sdkVersion) {throw 'Pinned .NET SDK required'}
    function Build-Project([string]$Name,[string]$Generated='') {
        $obj=(Join-Path $WorkRoot ($Name+'-obj'))+$separator
        $output=(Join-Path $WorkRoot ($Name+'-bin'))+$separator
        $props=@('-p:ImportDirectoryBuildProps=false','-p:ImportDirectoryBuildTargets=false','-p:CustomBeforeMicrosoftCommonTargets=','-p:CustomAfterMicrosoftCommonTargets=','-p:UseSharedCompilation=false','-p:NuGetAudit=false','-p:AppendTargetFrameworkToOutputPath=false',('-p:BaseIntermediateOutputPath='+$obj),('-p:MSBuildProjectExtensionsPath='+$obj),('-p:OutputPath='+$output))
        if ($Generated) {$props+=('-p:PinnedDataTypesPath='+$Generated)}
        $path=Join-Path $project "$Name/$Name.csproj"
        Invoke-Bounded 'dotnet' (@('restore',$path,'--configfile',(Join-Path $project 'NuGet.Config'),'--verbosity','quiet')+$props) (Join-Path $EvidenceRoot ($Name+'-restore.txt'))
        Invoke-Bounded 'dotnet' (@('build',$path,'--no-restore','--disable-build-servers','--verbosity','quiet')+$props) (Join-Path $EvidenceRoot ($Name+'-build.txt'))
        return $output
    }
    $extractor=Build-Project 'Extractor'
    $generated=Join-Path $WorkRoot 'PinnedDataTypes.cs'
    $declarations=Join-Path $EvidenceRoot 'declaration-hashes.json'
    Invoke-Bounded 'dotnet' @((Join-Path $extractor 'Thumble.CandidateApiConformance.Extractor.dll'),(Join-Path $SourceRoot 'sdk/HIDMaestro.Core/HMGamepadState.cs'),$generated,$declarations,(Join-Path $SourceRoot 'LICENSE')) (Join-Path $EvidenceRoot 'extractor.txt')
    $oracle=Build-Project 'Oracle' $generated
    $cargoTarget=Join-Path $WorkRoot 'rust-target'
    Invoke-Bounded 'cargo' @('+1.88.0','build','--locked','--manifest-path',(Join-Path $project 'emitter/Cargo.toml'),'--target-dir',$cargoTarget) (Join-Path $EvidenceRoot 'emitter-build.txt')
    $fixture=Get-Content -Raw (Join-Path $project '../../../Host/fixtures/gamepad/v2.json') | ConvertFrom-Json
    $reports=[Collections.Generic.List[string]]::new()
    foreach ($row in $fixture.vectors) {$reports.Add($row.hex)}
    foreach ($axis in 0..3) {foreach ($value in @(-32768,-1,0,1,32767)) { $bytes=[byte[]]::new(20);$bytes[1]=20;$bits=[BitConverter]::GetBytes([int16]$value);$bytes[6+$axis*2]=$bits[0];$bytes[7+$axis*2]=$bits[1];$reports.Add([Convert]::ToHexString($bytes).ToLowerInvariant()) }}
    foreach ($left in @(0,1,127,128,254,255)) {foreach ($right in @(0,1,127,128,254,255)) {$bytes=[byte[]]::new(20);$bytes[1]=20;$bytes[4]=$left;$bytes[5]=$right;$reports.Add([Convert]::ToHexString($bytes).ToLowerInvariant())}}
    foreach ($buttons in @(0xf7f0,0x0800,3,12)) {$bytes=[byte[]]::new(20);$bytes[1]=20;$bytes[2]=$buttons -band 255;$bytes[3]=$buttons -shr 8;$reports.Add([Convert]::ToHexString($bytes).ToLowerInvariant())}
    $reserved=[byte[]]::new(20);$reserved[1]=20;$reserved[19]=1;$reports.Add([Convert]::ToHexString($reserved).ToLowerInvariant())
    $header=[byte[]]::new(20);$reports.Add([Convert]::ToHexString($header).ToLowerInvariant())
    $extension=if ($IsWindows) {'.exe'} else {''}
    $emitter=Join-Path $cargoTarget ('debug/thumble-windows-candidate-state-emitter'+$extension)
    $rows=Join-Path $WorkRoot 'candidate-states.jsonl'
    $reports | & $emitter | Set-Content -Encoding utf8 $rows
    if ($LASTEXITCODE -ne 0 -or (Get-Item $rows).Length -gt 2MB) {throw 'Candidate rows invalid or oversized'}
    Invoke-Bounded 'dotnet' @((Join-Path $oracle 'Thumble.CandidateApiConformance.Types.dll'),$rows,(Join-Path $SourceRoot 'profiles/microsoft/xbox-360-wired.json')) (Join-Path $EvidenceRoot 'oracle.json')
    $result=Get-Content -Raw (Join-Path $EvidenceRoot 'oracle.json') | ConvertFrom-Json
    if ($result.cases -ne $reports.Count -or $result.officialSdkAssembly -or $result.sdkContextCompiled -or $result.sdkControllerCompiled -or $result.driverExecuted) {throw 'Unexpected conformance result'}
    @{version=1;scope=$pin.assemblyScope;commit=$pin.commit;sdkVersion=$version;sourceHashes=$pin.files;generatedDataSha256=(Get-FileHash -Algorithm SHA256 $generated).Hash.ToLowerInvariant();outputHashes=@{extractor=(Get-FileHash -Algorithm SHA256 (Join-Path $extractor 'Thumble.CandidateApiConformance.Extractor.dll')).Hash.ToLowerInvariant();oracle=(Get-FileHash -Algorithm SHA256 (Join-Path $oracle 'Thumble.CandidateApiConformance.Types.dll')).Hash.ToLowerInvariant();emitter=(Get-FileHash -Algorithm SHA256 $emitter).Hash.ToLowerInvariant();candidateRows=(Get-FileHash -Algorithm SHA256 $rows).Hash.ToLowerInvariant()};cases=$result.cases;rejectedReports=$result.rejectedReports;adversarialCases=$result.adversarialCases;officialSdkBuilt=$false;upstreamTargetsExecuted=$false;deviceCreated=$false;driverExecuted=$false;gameplayVerified=$false} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $EvidenceRoot 'manifest.json')
    Copy-Item (Join-Path $SourceRoot 'LICENSE') (Join-Path $EvidenceRoot 'upstream-MIT-LICENSE.txt')
    if (Get-ChildItem $EvidenceRoot -Recurse -File | Where-Object {$_.Extension -notin @('.json','.txt')}) {throw 'Unexpected evidence payload'}
} finally {Pop-Location}
