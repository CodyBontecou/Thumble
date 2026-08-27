# Thumble launch site

Pixel-art landing page for Thumble with a Cloudflare Pages Function that saves launch-list emails into Cloudflare D1.

## Files

- `index.html` / `styles.css` / `script.js` — static landing page, screenshot gallery, and launch-list form.
- `docs.html` — comprehensive Thumble documentation for setup, pairing, skins, editor workflows, outputs, CLI, troubleshooting, and safety behavior.
- `blog.html` + `blog/` — the Thumble blog index and posts. Posts are static pages that reuse the docs article styles; add a new card to `blog.html` per post.
- `skins.html` / `skins.js` — searchable, filterable skin directory with package verification, Web Share installation, direct downloads, and detail deep links.
- `skins/catalog.source.json` — editorial catalog data; `skins/catalog.json`, packages, and previews are generated deployable assets.
- `skins/CONTRIBUTING.md` — reviewed community submission workflow.
- `functions/api/subscribe.js` — Cloudflare Pages Function for `POST /api/subscribe`.
- `functions/api/releases/latest-mac.js` — serves the current macOS release manifest from R2.
- `functions/api/download-mac.js` — streams the latest/versioned macOS release zip from R2.
- `schema.sql` — D1 table and indexes.
- `wrangler.toml` — Pages + D1/R2 binding config. Replace the placeholder `database_id` before deploy.
- `config.js` — optional public Turnstile site key.

## Cloudflare setup

From the repo root:

```bash
cd Website
wrangler d1 create pocketpad-waitlist
```

Copy the returned database ID into `wrangler.toml`, replacing `REPLACE_WITH_D1_DATABASE_ID`, then create the table:

```bash
wrangler d1 execute pocketpad-waitlist --file=./schema.sql --remote
```

Create the release bucket and Pages project, then add a salt used for hashing IPs in consent/abuse records:

```bash
wrangler r2 bucket create pocketpad-releases
wrangler pages project create pocketpad-site --production-branch main
openssl rand -hex 32 | wrangler pages secret put IP_HASH_SALT --project-name pocketpad-site
```

Deploy to Cloudflare Pages:

```bash
wrangler pages deploy . --project-name pocketpad-site
```

For a Git-connected Pages project, set:

- Root directory: `Website`
- Build command: empty
- Build output directory: `.`
- D1 binding: `DB` → `pocketpad-waitlist`
- R2 binding: `RELEASES` → `pocketpad-releases`

## Optional Cloudflare Turnstile

1. Create a Turnstile widget in Cloudflare.
2. Put the public site key in `Website/config.js`.
3. Store the secret key:

```bash
wrangler pages secret put TURNSTILE_SECRET_KEY --project-name pocketpad-site
```

If `TURNSTILE_SECRET_KEY` is set, the API requires a valid Turnstile token.

## macOS release upload

From the repo root, build, notarize, upload the zip to R2, and update `macos/latest.json`:

```bash
scripts/release/macos-cloudflare.sh --version 1.0.0 --build-number 1
```

Use `--skip-upload` for a local dry run, or `--skip-notarize` only for unsigned internal previews. The script uploads to the remote R2 bucket with `wrangler r2 object put --remote` and can notarize through the configured `asc` API key.

## Local development

```bash
cd Website
wrangler d1 execute pocketpad-waitlist --file=./schema.sql --local
wrangler pages dev .
```

Then open the local URL shown by Wrangler. The form endpoint is `/api/subscribe`.

## Build and verify the skin directory

Build the current `thumble` CLI first, then generate versioned packages, clean previews, hashes, and the deployable catalog:

```bash
scripts/build-skin-directory.sh /path/to/thumble
```

Production publishes exact human-approved package bytes for Indigo Pocket, Solar Sumi, Tideglass Field, and Foldline Relay. The builder verifies every approval record and package hash, runs strict package and quality validation, creates native-renderer directory previews, and finishes with the dependency-free directory verifier. Run the verifier directly after any hand edit:

```bash
python3 scripts/verify-skin-directory.py
```

Approved package filenames include their semantic version and a SHA-256 prefix, preventing stale negative caches while preserving immutable delivery. `catalog.json` has a short cache and is the only runtime data source used by `skins.js`. Install buttons verify the downloaded byte count and SHA-256 before opening the system Share Sheet or downloading a `.pocketpad` file.

## Export signups

```bash
wrangler d1 execute pocketpad-waitlist \
  --remote \
  --command "SELECT email, source, consented_at, country FROM waitlist_subscribers ORDER BY created_at DESC;"
```
