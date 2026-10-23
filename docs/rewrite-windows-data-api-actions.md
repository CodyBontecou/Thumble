# Windows data API subset Actions gate

`.github/workflows/typescript-rewrite-windows-data-api.yml` runs the independent harness documented in `Rewrite/native/windows-sdk-conformance/README.md`. It checks mapping into four actual pinned HIDMaestro data declarations. It does not build the official SDK project, compile device/context/controller types, install or probe a driver, create a controller, submit input, sign files, or establish gameplay compatibility.

The Windows 2022 job uses read-only repository permission, checkout without persisted credentials, and Rust 1.88.0, matching the existing native gates. It fetches the public upstream tree without a credential helper, disables checkout newline conversion, and verifies exact commit and input hashes before compilation. The standalone script rejects a dirty or different checkout.

The job downloads the official portable .NET SDK **10.0.402 Windows x64 ZIP**, checks its exact SHA512 before extraction, and puts only that SDK on its step PATH. It never runs an installation script. Archive provenance is Microsoft's [10.0 release metadata](https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json); the pinned [archive](https://builds.dotnet.microsoft.com/dotnet/Sdk/10.0.402/dotnet-sdk-10.0.402-win-x64.zip) SHA512 is:

```text
ae4fd528cb7e9f6af6aaf7de36715a69f761f183744f1bb3025d19f5a92447090ec561410e46266c1d10a63781ed6f3de771760bc76c876d87daabc367b898cd
```

`global.json` disables SDK roll-forward, and the script checks the selected SDK version. Telemetry, tool-path changes and first-use ASP.NET development certificate generation are disabled before .NET runs. Builds use explicit owned projects, isolated intermediates, empty package sources, and no upstream MSBuild imports. Full upstream MIT attribution accompanies the text evidence; generated vendor declarations remain temporary.

The final upload selects only `data-api-evidence/*.txt` and `*.json`, with seven-day retention. It excludes the upstream checkout, SDK archive/tree, generated declarations, assemblies and Rust binaries. The evidence contains bounded logs, source/declaration/output hashes, oracle counts and explicit false device/driver/gameplay claims. A failed build may upload partial diagnostic evidence without representing a passing gate.

The workflow supports manual dispatch and path-filtered pull requests/main pushes. Local inspection uses:

```powershell
pwsh -NoProfile -File Rewrite/tooling/windows-candidate-api-conformance.ps1 -Mode Plan
pwsh -NoProfile -File Rewrite/tooling/windows-candidate-api-conformance.ps1 -Mode ValidateOnly -SourceRoot C:/work/hidmaestro
pwsh -NoProfile -File Rewrite/tooling/windows-candidate-api-conformance.ps1 -Mode Run -SourceRoot C:/work/hidmaestro -WorkRoot C:/work/data-api-build -EvidenceRoot C:/work/data-api-evidence -ConfirmDataOnly
```

The local macOS result is 96 report rows, including five rejected reports, plus six adversarial state cases. This workflow needs its own exact-head Windows result before Windows data API conformance can be claimed. Neither platform result establishes official SDK lifecycle or virtual-controller functionality.
