# Desktop receiver release — October 26, 2026

Receiver PR #1 merged as `8b2e623b62c188434310412702663a573fa5afe7`.
Distribution PR #2 merged as `6c080962f58c85bf638db5c3231d8cf2d2a215c4`.

- Native artifact CI: https://github.com/CodyBontecou/Thumble/actions/runs/40340945340
- Receiver merge CI: https://github.com/CodyBontecou/Thumble/actions/runs/40342778080
- Distribution main CI: https://github.com/CodyBontecou/Thumble/actions/runs/40344606629
- Final production Pages deployment: https://365a2132.pocketpad-site.pages.dev
- Download Worker version: `48fd48b7-7504-471f-833f-d054982d113c`
- Live downloads: https://thumble.io/#download
- Setup guide: https://thumble.io/docs#desktop-receivers

All eight new public files were downloaded through thumble.io and matched the local verified release files. `public-verification.json` records hashes and sizes. Original Windows/Linux package bytes match passing CI artifacts. Public GET/HEAD and four latest aliases passed. Mac legacy API and existing CLI downloads remain functional. Homepage and docs match the reviewed source; about copy is correct (Cloudflare obfuscates its contact email). Markdown negotiation now includes the updated download cards, setup section and about copy.

`downloads.png` shows the live website. Windows/Linux are explicitly unsigned 0.1.0 previews, including ViGEmBus/uinput requirements, pending real-game acceptance and upcoming public phone apps. The Mac download remains the signed/notarized 1.0.0 DMG.

The exact patch for separately hosted HTML source is committed under `apps/downloads/website/desktop-downloads.patch`; its three page changes are also applied in the actual legacy Website source. Generated Markdown was rebuilt with `node build-markdown.mjs .` before the final production deployment. Run this generator whenever website copy changes and preserve the published `/cli/` files when assembling another deployment.
