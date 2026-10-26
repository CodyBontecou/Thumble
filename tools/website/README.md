# Website optimization

The thumble.io source currently lives in `../Thumble-legacy/Website` and deploys to Cloudflare Pages project `pocketpad-site`. Keep published CLI downloads when assembling a deployment; they are not in that source folder.

Install this tool's dependencies with `npm install --prefix tools/website`, then run:

```
node tools/website/optimize-lighthouse.mjs /absolute/path/to/Website
```

This creates content-hashed responsive WebP screenshots and ability icons, updates matching HTML references, and inlines minified page styles at their original cascade positions. Homepage and waitlist CSS also exclude selectors absent from their HTML and behavior script, with dynamic form and FAQ attributes preserved. The PNG originals and other pages' stylesheets remain available. Rerun after changing CSS to refresh the generated `data-inline-css` blocks. It preserves copy, image dimensions, alt text and signup behavior.

The October 26 baseline and live verification reports are in `docs/evidence/lighthouse-2026-10-26`.
