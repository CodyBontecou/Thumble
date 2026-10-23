# Headless Windows optical capture helper

This isolated helper implements the existing private capture child contract without a Thumble desktop application. It depends on the unchanged pure `../windows-optical` decoder. It has no receiver, pairing, authority, input or configuration database dependency. No screenshots or window identities are logged or sent to TypeScript. Only the validated 512-byte optical frame and a PNG of the same capture's 256-square atlas may leave the child.

Build and synthetic verification:

```sh
cargo +1.88.0 test --locked --manifest-path Rewrite/native/wow-capture-windows/Cargo.toml
cargo +1.88.0 clippy --locked --manifest-path Rewrite/native/wow-capture-windows/Cargo.toml --all-targets -- -D warnings
bun Rewrite/tooling/windows-capture-notices.ts --check
bun Rewrite/tooling/test-windows-optical-parity.ts
bun Rewrite/tooling/test-windows-capture-interop.ts
```

The dedicated Actions workflow compiles Windows APIs and runs fake-provider tests and synthetic raster oracles on Windows, Linux and macOS. It never invokes the helper executable, capture, permission inspection/request, OS window enumeration or a GPU device. No binaries, captures, native identities or toolchains are uploaded. The helper binary is not installed or included in product packaging by this slice.

## Explicit executable modes

- Default / `--status`: read-only `AppCapability.CheckAccess` for `graphicsCaptureProgrammatic`. `Allowed` is `authorized`; known denials/prompt requirements are `permission-required`; an unsupported/undeclared inspection is `not-inspected`. This never selects a source, creates a capture item or infers authorization from `IsSupported`.
- `--request-permission`: explicitly requests programmatic access, returning the OS access result or `unavailable`. Unpackaged/version/policy behavior remains a Windows beta gate. It never selects a source or suppresses the OS border.
- `--capture`: one strict 256-byte ASCII JSON request at a time, prefixed by an unsigned big-endian u32 length. Responses echo the exact issued source/generation/receipt and use the existing bounded frame/status schema. Invalid/truncated input terminates with a fixed protocol error. Parent TypeScript owns timeouts, helper termination, capture generation, freshness and authority application; this helper does not invent new receipts or authority acknowledgments.

Permission modes share the existing framed permission command names; the TypeScript adapter must admit `not-inspected` and `unavailable` as inspection outcomes without granting capture admission. Unsupported platforms return a fixed protocol error; there is no GDI/desktop/monitor fallback.

## Private source identity and binding

Source requests cannot contain an HWND, PID, executable path, picker choice or crop. The adapter enumerates at most 4,096 top-level windows and stops once two eligible visible, non-minimized game windows make selection ambiguous. Eligibility retains the existing `_classic_era_` / `_forever_` client-root restriction from `Sources/Bridge/WoWLiveCapture.swift`; Windows additionally requires a matching `Wow.exe`/`WowClassic.exe` filename, PE `OriginalFilename`, and `ProductName` exactly `World of Warcraft`. These mutable strings are an eligibility policy, **not executable authenticity or signature verification**. Exact Classic Era/Forever client builds, translations and custom clients remain compatibility acceptance work; unknown paths/metadata fail closed.

The helper binds the first eligible native context privately to the pointer-width HWND, PID and process creation time, discovered full executable path, opened file's 128-bit ID plus volume/size/modification identity, window/client/DWM frame rectangles, per-window DPI, and acquired WGC pixel dimensions. The opened file’s normalized final DOS path must match the process-discovered path; parent-junction aliases and traversal cannot widen client-root eligibility. Process and EXE handles remain open across acquisition; EXE sharing permits reads only. Native identity is re-read before and after the WGC wait, and inventory must still contain exactly the original single window afterward. Window replacement, PID reuse, EXE replacement, resize, DPI changes, stale receipts or source/generation change invalidate this child; it never silently retargets. A new supervisor generation/child is required. Panel absence preserves the same private context for a later receipt.

## Capture, bounds and cancellation

The adapter uses Win32 `IGraphicsCaptureItemInterop::CreateForWindow` and a fresh `Direct3D11CaptureFramePool.CreateFreeThreaded` with two BGRA8 buffers per request. A fresh pool cannot return an earlier request's queued frame. It leaves the standard Windows border/policy untouched, without picker UI or border-suppression requests. A frame-arrival wait is bounded to 750ms; the parent remains responsible for killing a stalled child around GPU/OS calls. This is not a hard realtime guarantee for arbitrary GPU drivers.

A read-only staging map must match validated capture dimensions, stride and BGRA8 format, with a maximum 64MiB mapped view / 16,777,216 pixels / 8,192-pixel edge. The pure decoder reads that view directly under its existing four-million-read budget; there is no second whole-window pixel allocation. Its exact 256-square RGBA atlas is encoded losslessly into a fixed RGB-alpha PNG using bounded stored DEFLATE blocks, CRCs and Adler-32. The framed TypeScript interop oracle verifies the real strict reply codec, optical frame validation, PNG container/CRC checks, actual bounded decompression, and every decoded RGBA byte.

RAII retains the frame and staging texture through decode, unmaps before resource release, removes the event handler and closes the capture session/pool. Callback storage owns only a bounded channel sender; no borrowed stack pointer crosses the callback. Errors expose fixed statuses only. No actual WGC session, permission request, gameplay, latency, protected-window/HDR support, signing or production distribution has been accepted by synthetic CI.

## API provenance and notices

Bindings are pinned to Microsoft `windows` 0.61.3 and the complete Cargo lock. No upstream implementation is vendored. `THIRD-PARTY-NOTICES.txt` is checked against the lock and every registry dependency's actual license text, including Unicode data notices. Build validation does not establish distribution/signing acceptance.

Primary Microsoft references: [CreateForWindow](https://learn.microsoft.com/en-us/windows/win32/api/windows.graphics.capture.interop/nf-windows-graphics-capture-interop-igraphicscaptureiteminterop-createforwindow), [CreateFreeThreaded](https://learn.microsoft.com/en-us/uwp/api/windows.graphics.capture.direct3d11captureframepool.createfreethreaded), [RequestAccessAsync](https://learn.microsoft.com/en-us/uwp/api/windows.graphics.capture.graphicscaptureaccess.requestaccessasync), and [capability declarations](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/app-capability-declarations). The Win32 interop API is documented for Windows10 version1903 and later; this source requires newer DPI/permission APIs where called and fails closed when unavailable. Real Windows acceptance remains pending.
