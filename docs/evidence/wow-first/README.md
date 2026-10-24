# WoW and ConsolePort positioning — 24 October 2026

The app and thumble.io now introduce phone controls for WoW on Mac with ConsolePort. Welcome enters the guided WoW setup directly. The default flow is client selection → Mac connection → matching ConsolePort preparation → one five-check in-game checklist. The welcome CTA is fixed in the footer so it remains available in landscape. Pricing, requirements, pairing instructions, support and public launch-update copy use the same scope.

AI controller generation remains disabled. Existing profile and progress storage is preserved. No live WoW checks were synthesized or checked on the player's behalf.

Validation:
- `npm test`: 217 passed.
- Mobile `npm run lint` and `npm run typecheck`: passed.
- Changed app/docs and website source `git diff --check`: passed. An unrelated marketplace listing has existing trailing Markdown whitespace and was not edited.
- Website: 12 HTML files checked for local links/anchors. Browser screenshots reviewed at 1280px and 390px; no horizontal overflow or broken homepage images.
- Recorded first-run path: `.argent/e2e/wow-consoleport-first-run-final.yaml`, replayed successfully on isolated `com.thumble.wowsetupqa` after fresh install. Recorded coordinate taps were replaced with the actual UI text selectors and successfully replayed; final YAML retains no raw coordinates. Prefix-only earlier replay also passed. Early failed takes are retained as `.txt` for diagnosis, not active regression tests.
- Replay command: `argent e2e run wow-consoleport-first-run-final --platform ios --device <simulator-id>`. Reinstall the isolated QA app before replay; launch does not clear saved progress.
- Video: `.argent/recordings/screen-recording-2C25402F-F87F-46EA-A615-A1A9C0689EC6-1792866533641.mp4` (3.4 seconds, static sections trimmed). Recordings are ignored by git. This records welcome → client picker → connection; it does not prove live game compatibility.
- Release iOS/Android builds succeeded with `EXPO_PUBLIC_AI_CONTROLLER_GENERATOR_ENABLED=false`.
- Both installed as updates on the connected iPhone 13 Pro Max and Pixel 7 without clearing app data.

Website source: `/Users/codybontecou/dev/thumble/Website`. Source hashes were checked before copying from staging to avoid overwriting concurrent edits. Existing Functions, waitlist forms, D1/R2 bindings and legal prose were preserved. Published to the existing Cloudflare Pages production branch (`pocketpad-site`, main): https://5c6508c7.pocketpad-site.pages.dev . The live https://thumble.io homepage was verified in the browser and captured in `website-live.png`.
