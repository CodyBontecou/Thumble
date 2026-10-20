# Native app review

Final package: `build/warband-command-1.0.0.pocketpad`.
SHA-256: `494f1af8f1bff172e754fb35a5dd3981f0a514b1c6114d6ca1f3b0af14d674af`.
Final canonical native matrix: `contact-sheet-4.png`; independent visual pass: `critique-3.md`; independent QA: `qa-report.md`.

Built the current ThumbleiOS working tree with Xcode in `build/WarbandPreviewDerivedData` and installed it only in the isolated **Thumble App Store Capture** iPhone simulator on iOS 26.5. The existing website and personal Mac/physical-phone setups were not changed by this skin task. The preview fixture is a new named Warrior profile, generated from the exported canonical `wow-forever-v1` artboard. Native profile normalization remaps custom control IDs; the input bindings and geometry remain canonical. Fixture creation does not install anything; see `../preview/prepare-preview.py`.

The final skin was installed in that simulator's app data skin library. Saved Keypad was opened through the app UI, with **Practice Mode enabled and outgoing input off**. The offline connection bar stays pinned open by the app, so it remains visible in these captures.

All screenshots are full-resolution native app captures, with only the screenshot tool's orthogonal orientation correction. No controller controls, icons, state labels, backgrounds, or visual decoration were composited onto screenshots.

- `app-landscape-base.png`: released Base state.
- `app-landscape-lt.png`: LT held; cool bank accent, changed ability pictures, LT HELD.
- `app-landscape-rt.png`: RT held; warm bank accent, changed ability pictures, RT HELD.
- `app-landscape-both.png`: both held; combined accent, changed ability pictures, both HELD.

Before each held-bank capture the live AX-service confirmed the corresponding native trigger's Pressed value. Each hold was released afterward; the app returned to Base. `warband-command-modifiers` recorded/replayed this path uninterrupted: 9 passed, 0 failed, 0 errored. The earlier `warband-command-preview` path also replayed successfully in its original capture orientation.

The flows are device/orientation-specific visual review aids. The UIKit flow projection omits SwiftUI connection controls and Pressed accessibility values, so the recordings retain explicit raw AX-service waits. View Saved Keypad's native target could not be found through native-find-views/full hierarchy and its text assertion failed in a scratch flow; its recorded tap therefore uses the live accessibility frame. Multitouch holds use raw gesture events by design. These are disclosed coordinate exceptions, not portable QA or gameplay acceptance claims.

The active iPhone app is also available through a local serve-sim mirror, bound only to this simulator. The browser shows a real live frame. Mirror helper remains running for user review, with scoped cleanup trap on exit.

Required repository `scripts/verify-stack-safety.sh` passed on the current working tree. The iPhone app build succeeded. This task made no application-source changes.

Ability images are explicitly configured examples using the existing Blizzard icon sources and attribution; there is no class detection, live spell assignment, cooldown feed, or live WoW session in these captures. Human approval remains pending. No catalog publication, deployment, staging, commit, or push occurred.
