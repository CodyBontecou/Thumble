# Website tooling

Production source is `apps/website` in this repository. Cloudflare Pages project `pocketpad-site` serves thumble.io; the separate receiver download Worker remains in `apps/downloads`.

From the repository root (Node 24 or newer):

```sh
npm run website:test
npm run website:build
npm run website:dev
npm run website:deploy
```

Tests and the standard build need only Node built-ins. Preview and deploy additionally require Wrangler v4 and an authorized Cloudflare login. Relevant pushes to `main` automatically deploy the tested `dist/website` artifact and verify it; pull requests only run checks. Manual workflow dispatch on `main` can retry a deployment. `website:deploy` remains a local fallback for building and deploying to production branch `main`. `website:dev` initializes the idempotent waitlist schema and previews that artifact with local D1/R2 simulation persisted under ignored `build/website-local`; configure preview-only secrets locally if required. Production secrets stay in Cloudflare.

`build.mjs` selects public content and Functions, regenerates negotiated Markdown, and keeps SQL, migration/report files, source-generation tools and readmes out of the public artifact. The artifact contains the existing Wrangler bindings for deployment. Do not deploy `apps/website` directly.

## Existing CLI downloads

`apps/website/cli-distribution.json` pins the existing public script and archive hashes. The script comes from `packages/cli/src/thumble.mjs`. The archive is fetched once from its published URL and cached under ignored `build/website-downloads`. It intentionally preserves the website archive, whose bytes differ from the npm registry archive for the same version. A mismatch fails the build instead of silently replacing a download.

For an offline build, provide a previously downloaded archive with the pinned hash:

```sh
npm run website:build -- --cli-archive /absolute/path/thumble-cli-0.1.0.tgz
```

New CLI releases must deliberately update the manifest. Generated `.tgz` files and build output are not committed.

## Image and CSS optimization

The existing optimizer has its own dependency lockfile:

```sh
npm ci --prefix tools/website
npm run website:optimize
npm run website:build
```

It creates content-hashed responsive WebP images and refreshes `data-inline-css` blocks at their original cascade positions. Run it after stylesheet edits; the standard build preserves the reviewed source HTML without requiring native image dependencies. Commit resulting source changes. Original PNGs remain available.

`artwork/waitlist-og.html` and `artwork/render-waitlist-og.cjs` rebuild the shared Open Graph image. This optional artwork command requires Playwright and Chromium; it is not required to build or deploy the site.

The October 26 performance evidence remains in `docs/evidence/lighthouse-2026-10-26`; SEO and Search Console records are in `docs/research` and `docs/evidence`.

## GitHub Actions deployment

The workflow needs `CLOUDFLARE_PAGES_API_TOKEN` as a repository secret, with Cloudflare Pages Edit permission limited to the production account. Set the non-secret `CLOUDFLARE_ACCOUNT_ID` repository variable to that account ID. The token is only injected into the production deployment step on main. PR checks never deploy. Deployments are serialized, Wrangler is pinned, and failed tests/builds prevent deployment. No database migration is run automatically.

`npm run website:verify` checks the live HTML, generated Markdown, sitemap, CSS, CLI bytes, real 404 and download HEAD responses against the local artifact. It retries short propagation/transient failures and fails the workflow if production differs. Run `npm run website:build` first when invoking verification locally.

The dedicated CI token was created October 26, 2026 and expires October 26, 2027. Rotate the encrypted repository secret before expiry. It grants Cloudflare Pages Edit for the production account and does not grant D1, R2 or Workers permissions.
