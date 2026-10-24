# Thumble brand assets

`public/assets/thumble/` contains the public PNGs served by the cloud Worker and
read by the local MCP server. `thumble.js` is the shared resource allowlist.
Only this public directory is uploaded; source files, credentials, screenshots
and third-party ConsolePort artwork are not part of the asset bundle.

The PNGs are snapshots of the mobile app's artwork. After changing a mobile
brand asset, update its copy here before deploying:

```sh
cp apps/mobile/assets/icon.png apps/mobile/assets/favicon.png apps/mobile/assets/splash-icon.png apps/mobile/assets/thumble-menu.png assets/public/assets/thumble/
```

The cloud asset tests check byte parity with the mobile originals.
