# Pinned HIDMaestro data API conformance subset

This independent harness checks the unchanged `windows-candidate` Rust mapping against actual data declarations from HIDMaestro 2.0.3 commit `63cc6481f9e82fc8600bda8aaa65cb3271113a19`. It compiles **a data-type subset, not the official SDK assembly**. It provides no driver/backend adoption, device discovery, installation, controller creation, output submission, readback, signing, or gameplay evidence.

The upstream SDK project imports build-time resource packing and generation. This harness never imports that project or its targets. Its own Roslyn extractor checks the exact input SHA256, namespace, public fields without initializers, enum declarations and permitted syntax, then copies only `HMGamepadState`, `HMAxis`, `HMButton`, and `HMHat` into a temporary generated file. It excludes `HMGamepadStateHelpers` and all context, controller, profile, device and resource code. Both owned projects explicitly enumerate compile inputs and restore with no package sources. SDK-bundled Roslyn is the only compiler API dependency. The pinned .NET SDK is **10.0.402**, with roll-forward disabled.

`pin.json` records exact upstream commit, source/profile/license SHA256 values and declaration names. Sources are retrieved from an independently checked-out, pristine upstream tree; no upstream source is committed here. The entire upstream MIT license, including its prefatory text and copyright, is copied to the evidence directory. This mapping adapter and oracle are independently written; extracted declarations retain their upstream license and provenance.

- [Pinned data declarations](https://github.com/hifihedgehog/HIDMaestro/blob/63cc6481f9e82fc8600bda8aaa65cb3271113a19/sdk/HIDMaestro.Core/HMGamepadState.cs)
- [Pinned Xbox profile](https://github.com/hifihedgehog/HIDMaestro/blob/63cc6481f9e82fc8600bda8aaa65cb3271113a19/profiles/microsoft/xbox-360-wired.json)
- [Complete upstream MIT license](https://github.com/hifihedgehog/HIDMaestro/blob/63cc6481f9e82fc8600bda8aaa65cb3271113a19/LICENSE)

Run from the repository root with PowerShell 7, Rust 1.88.0 and .NET SDK 10.0.402 available:

```powershell
# Prints the execution scope without inspecting upstream or compiling.
pwsh -NoProfile -File Rewrite/tooling/windows-candidate-api-conformance.ps1 -Mode Plan

# Checks exact commit, clean tree and every pinned input hash; does not compile.
pwsh -NoProfile -File Rewrite/tooling/windows-candidate-api-conformance.ps1 `
  -Mode ValidateOnly -SourceRoot C:/work/hidmaestro

# Both output directories must be new, separate, and outside source/project.
pwsh -NoProfile -File Rewrite/tooling/windows-candidate-api-conformance.ps1 `
  -Mode Run -SourceRoot C:/work/hidmaestro `
  -WorkRoot C:/work/api-data-build -EvidenceRoot C:/work/api-data-evidence `
  -ConfirmDataOnly
```

The script isolates .NET home/MSBuild extensions and disables directory-wide MSBuild imports, shared compilation, telemetry, global tool-path changes, and first-use ASP.NET certificate generation. Microsoft documents `DOTNET_GENERATE_ASPNET_CERTIFICATE` in its [SDK environment variables](https://learn.microsoft.com/dotnet/core/tools/dotnet-environment-variables). It uses no credentials or NuGet packages. Upstream source and .NET installation must already be available; the script downloads neither.

The Rust emitter calls the frozen pure candidate crate, emitting bounded JSON with exact float bits. The C# adapter constructs the real pinned data struct. The independent oracle checks all retained v2 report vectors, signed extrema and near-zero axes, independent trigger pairs, button/Guide flags, diagonal hats, reserved bytes/bits, and contradictory hats. It rejects malformed mapped JSON, duplicate usages/keys, nonfinite axis data, unknown flags and invalid hats. No implicit deadzone, neutral adjustment or second Y inversion is applied. The first verified macOS run processed 96 rows, including five rejected reports, plus six adversarial mapped-state cases. Windows execution requires its separate Actions gate.

Generated upstream declarations, assemblies, Rust binaries, package caches and build intermediates stay under `WorkRoot`. Only bounded text/JSON logs, declaration hashes, the source/output hash manifest and upstream MIT notice go under `EvidenceRoot`. Publish only that evidence directory; do not upload `WorkRoot` or redistribute the toolchain or generated subset assembly. A successful gate establishes this narrow source data API compatibility; it does not establish compatibility with `SubmitState` or any operational SDK/device lifecycle.
