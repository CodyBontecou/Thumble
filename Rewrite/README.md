# Thumble rewrite workspace

Isolated M2 implementation under coexistence. Bun **1.4.3** and TypeScript **6.0.3** are pinned; install with `bun install --frozen-lockfile`, then `bun run verify`.

Current scope: portable semantic gamepad schema, generated TypeScript/Swift/Kotlin DTOs, strict immutable state validation and retained v2 HID report conformance. The 34 native vectors remain owned by `Host/fixtures/gamepad/v2.json`. DTO generation is not native input-module or authenticated transport acceptance. The pure report encoder preserves native nonfinite/clamp behavior for conformance; external state validation rejects nonfinite/out-of-range values before activation.

`bun run generate` updates all bindings; `bun run check:generated` detects drift. Contracts and domain are compiled without Bun/Node/DOM globals and checked for forbidden dependency paths. Host code may depend on portable packages; mobile must not import host application/storage implementations.

GitHub Actions runs the same strict/generated/boundary/test checks on Windows, macOS and Linux, plus Swift DTO typechecking on macOS. Windows receiver CI runs without an interactive desktop, saves a read-only XInput observation and builds the consumer witness for beta testing. Missing hardware on a runner never counts as gameplay success.

All development is headless. Windows, iOS, Android and required optical live sync remain launch scope. Driver/signing/install, actual game recognition, multitouch/haptics, physical latency and live capture/delivery require eventual beta evidence. Those are release/retirement gates, not prerequisites for writing isolated implementation.

Remaining M2 work: versioned receiver/configuration seam, isolated local IPC/service/CLI lifecycle and lease-expiry integration, native input-module skeletons and mobile build CI, compiled Bun packaging and signed-helper acceptance. No production runtime is routed through this workspace yet; no new network listener or native input path is enabled.

The retained v2 fixture includes the upstream compatibility descriptor; its MIT notice is preserved in `ThirdParty/SteamControllerBridge-LICENSE.txt`.
