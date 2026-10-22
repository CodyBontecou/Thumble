# Windows candidate unsigned compile experiment

This harness evaluates whether the pinned HIDMaestro 2.0.3 native UMDF and XUSB-companion sources compile on an x64 Windows Actions runner. It does not adopt a backend, instantiate the SDK, install/load a driver, create a controller, sign binaries, certify gameplay or publish a driver package. The receiver remains recording-only. The separate portable candidate crate tests report mapping only.

`Rewrite/tooling/windows-candidate-toolchain.json` pins upstream commit `63cc6481f9e82fc8600bda8aaa65cb3271113a19`, the SHA256 of both audited native entrypoints and their three script helpers, and the MIT/SDK notice files. NuGet package versions are all `10.0.26100.6584`: Windows.WDK.x64, Windows.SDK.CPP, and Windows.SDK.CPP.x64. Each archive has an exact official NuGet catalog SHA512 and length, checked before extraction. Kit paths use `10.0.26100.0` and UMDF 2.15. NuGet restore/build targets never execute. SDK common headers/tools and x64 UM libraries are explicitly assembled; the Visual Studio compiler and CRT selected by `vcvarsall` are recorded, not pinned. This is not a reproducible toolchain claim.

The exact upstream entrypoints are [`scripts/build.cmd`](https://github.com/hifihedgehog/HIDMaestro/blob/63cc6481f9e82fc8600bda8aaa65cb3271113a19/scripts/build.cmd) and [`scripts/build_companion.cmd`](https://github.com/hifihedgehog/HIDMaestro/blob/63cc6481f9e82fc8600bda8aaa65cb3271113a19/scripts/build_companion.cmd), invoked with `x64`. They call the audited compiler environment, version-header generator and INF stamp helper, compile/link native C resources, and stamp build-copy INFs. Neither entrypoint has a signing or installation stage to enable. The first also compiles the `hmswd.exe` device-creation helper; the harness never executes it or any compiled binary. `build_all`, managed SDK targets, examples, probes, installers, certificate tools and driver-store operations are outside this harness.

PowerShell 7 examples, from the repository root:

```powershell
./Rewrite/tooling/windows-candidate-build.ps1 -Mode Plan
# Fresh separate checkout: disable automatic line-ending conversion before checkout.
git -c core.autocrlf=false clone --no-checkout https://github.com/hifihedgehog/HIDMaestro.git C:/candidate-source
git -C C:/candidate-source -c core.autocrlf=false checkout --detach 63cc6481f9e82fc8600bda8aaa65cb3271113a19
./Rewrite/tooling/windows-candidate-build.ps1 -Mode ValidateOnly -SourceRoot C:/candidate-source
./Rewrite/tooling/windows-candidate-build.ps1 -Mode Build -SourceRoot C:/candidate-source -WorkRoot C:/candidate-tools -EvidenceRoot C:/candidate-evidence -ConfirmUnsignedCompileOnly
```

`Plan` needs no checkout or network and executes no upstream code. `ValidateOnly` checks the exact pristine commit and audited hashes, without downloads or compilation. Build requires explicit confirmation, x64 Windows, a fresh source build directory, and new non-overlapping tool/evidence directories. It rejects unexpected source changes before each entrypoint. A fresh runner with read-only repository permissions and no secrets is the intended execution context; no elevation is requested. The manifest records actual package/output hashes and unsigned Authenticode status for DLL/EXE outputs, and rejects catalogs/certificates/keys in build output. The source checkout must remain isolated from other build jobs.

Upload **only `EvidenceRoot`**: bounded build/compiler logs, the hash manifest and upstream MIT/SDK notices. Never upload the source `build` directory, downloaded kits, DLL/EXE/INF outputs or toolchain packages. An unsigned DLL/INF compilation result does not demonstrate clean installation, consumer readback, real input/neutralization, removal/coexistence, signing feasibility or launch support.

Microsoft documents [WDK NuGet installation](https://learn.microsoft.com/windows-hardware/drivers/install-the-wdk-using-nuget) and [driver signing](https://learn.microsoft.com/windows-hardware/drivers/develop/signing-a-driver) separately. The pinned WDK archive includes **MICROSOFT PRE-RELEASE SOFTWARE LICENSE TERMS**; the harness records license file hashes and does not establish production/distribution or disclosure clearance. The [SDK license](https://aka.ms/WinSDKLicenseURL), the exact package licenses, upstream MIT license and third-party notices remain independent review inputs. No binary/toolchain redistribution is authorized by this experiment. A public CI run/log-disclosure decision must account for those actual terms.

Initial local validation can establish manifest structure, source/script hashes and Plan/ValidateOnly semantics. Actual compilation and unsigned-output assertions require the dedicated Windows runner; record that result explicitly rather than claiming Windows execution from cross-compilation or static review.
