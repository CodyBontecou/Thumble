# Thumble launch site

Dark, product-focused site for Thumble, inspired by myself.md, with a Cloudflare Pages Function that saves launch-list emails into Cloudflare D1.

## Production domain

`thumble.io` was registered with Cloudflare on October 23, 2026 and added to the
existing `pocketpad-site` Pages project. Its proxied apex CNAME points to
`pocketpad-site.pages.dev`; the existing D1 and R2 bindings remain on that project.

The `isolated.tech` zone has a saved Single Redirect named
`Thumble website to thumble.io`. It matches only
`http.host eq "thumble.isolated.tech"` and redirects with status 301 to
`concat("https://thumble.io", http.request.uri.path)`, preserving query strings.
The rule was enabled on October 23, 2026 after verifying that `https://thumble.io`
serves the site with a valid certificate. Both HTTP and HTTPS old-domain requests
were verified to return 301 redirects preserving the path and query string; the
new domain's homepage and `/docs` returned 200. Some resolvers may temporarily
retain a negative DNS cache from before the registration's delegation appeared.

Public navigation, canonical URLs, Open Graph and Twitter image URLs use
`https://thumble.io`. Canonical page paths omit `.html`, matching Pages' redirects.
`sitemap.xml` lists indexable pages and is advertised by `robots.txt`; the 404,
signup confirmation and retired skin notice remain excluded from the sitemap.

## Files

- `index.html` / `waitlist.html` / `landing.css` — shared visual direction: a centered headline, native controller preview, and compact signup card.
- `styles.css` / `design.css` — existing content layouts and the shared dark visual theme across every page.
- `script.js` — release availability, Turnstile, and launch-list forms.
- `docs.html` — comprehensive Thumble documentation for setup, pairing, editor workflows, outputs, CLI, troubleshooting, and safety behavior.
- `blog.html` + `blog/` — the Thumble blog index and posts. Posts are static pages that reuse the docs article styles; add a new card to `blog.html` per post.
- `skins.html` — retirement notice for old directory links; no catalog or downloads.
- `functions/api/subscribe.js` — Cloudflare Pages Function for `POST /api/subscribe`.
- `functions/api/releases/latest-mac.js` — serves the current macOS release manifest from R2.
- `functions/api/download-mac.js` — streams the latest/versioned macOS release zip from R2.
- `schema.sql` — D1 table and indexes.
- `wrangler.toml` — Pages + D1/R2 binding config. Replace the placeholder `database_id` before deploy.
- `config.js` — optional public Turnstile site key.

## Static design preview

Run `python3 -m http.server 8174 --directory Website` from the repository root.
The static preview covers the page layouts, FAQ, and direct appearance editing. Release
metadata and signup submission require the Cloudflare Pages runtime and bindings
described below. The launch hero keeps the controller and signup form in the first viewport on
small phones and desktop displays. Reduced-motion preferences disable decorative transitions.

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

## Retired skin directory

The public catalog, package downloads, previews, submission workflow, and catalog build scripts are removed. `skins.html` keeps old links useful by pointing to direct appearance editing. Test packages required for legacy profile migration live under `Host/fixtures/legacy-skin-packages` and are not deployed with the website.

## Export signups

```bash
wrangler d1 execute pocketpad-waitlist \
  --remote \
  --command "SELECT email, source, consented_at, country FROM waitlist_subscribers ORDER BY created_at DESC;"
```

## October 2026 feature copy baseline

The October 19 development update uses App Store Connect's latest iOS upload:
1.0.0 (6), July 30, 2026 (build ID `e47e3328-b217-4519-9138-ab0c418131e5`).
Read with `asc builds list --app com.codybontecou.PocketPad --platform IOS
--sort=-uploadedDate --limit 1 --include preReleaseVersion,betaBuildLocalizations`.
Development highlights are not claims about the downloadable build. Practice Mode,
thumb calibration, and orientation variants already existed at that baseline.
League is a custom keyboard/pointer use case, not a bundled preset. WoW Forever,
Thumble Link, receiver limits, and virtual gamepad acceptance boundaries follow
`docs/wow-forever.md`, `Addons/ThumbleLink/README.md`,
`docs/cross-platform-receiver.md`, `docs/receiver-qa-results.md`, and
`docs/virtual-controller-support.md`. Recheck these boundaries when publishing a beta.

## Gaming screenshot provenance

The hero defaults to the clean Warband Command native controller render.
Everyday Play uses its reviewed clean native controller render.

- Everyday Play 1.0.0: exact, unedited native-renderer output from
  `docs/skins/examples/everyday-play/reviews/landscape-dark-base-1.png`.
  Mineral keycaps and paired sea-glass/coral rims preserve canonical controls.
  Hero asset SHA-256: `b8e9ec1276a6c789bb13bc9aa69e07b1dd869f3bddad99b64ab86533b4c72fcf`.
  Full 16-frame review, original editable SVG/CSS and independent QA are retained
  in that workspace. Existing docs screenshots remain unchanged.

- Warband Command 1.0.2: exact, unedited native-renderer output from
  `docs/skins/examples/warband-command/reviews/landscape-dark-base-6.png`.
  The reviewed appearance package removes the passive bank reference; this clean
  render omits app toolbar chrome. Hero asset SHA-256: `67ae6f7fd33dba405f7a0e394b99e1fd3b8fa57079bd99ba502cd0a5bcea671d`.
  Full 64-frame review and independent QA are retained in that workspace.
  This is a configured Warrior example, not live WoW spell synchronization.

These images show configured controller UI, not live game recognition or input
acceptance. No controls or icons were composited onto the captures or render. Asset
filenames include SHA-256 prefixes because `/assets/*` is cached immutably.

## Waitlist landing page and sharing

The homepage includes a compact signup card beneath the controller showcase. Share
`https://thumble.io/waitlist` for the dedicated signup page, with the same card beneath its controller preview. The hero, dedicated
page, and footer all use `script.js` and `POST /api/subscribe`, with consent given by joining beneath a visible launch-update notice,
honeypot protection, inline feedback, and native HTML submission when
JavaScript is unavailable. Their source values are `hero`, `waitlist`, and `footer`.
Existing subscribers are updated rather than duplicated by the email constraint.

Both the homepage and `/waitlist` declare the 1200 × 630 PNG social card at
`/assets/og/waitlist-v5.png`, including Open Graph dimensions, alt text, and
Twitter's large-image card. Its editable HTML at `scripts/website/waitlist-og.html` and reproducible renderer are retained:

```bash
node scripts/website/render-waitlist-og.cjs
```

Run from the repository root with `playwright` available in Node's module resolution
and Chromium installed. The card uses the unchanged Warband Command native render
with the hero’s CSS perspective tilt; it does not author or
modify a controller skin. Change the versioned filename when updating the card,
because `/assets/*` uses immutable caching.

The waitlist and landing page describe the cross-platform rebuild targeting iOS,
Android, macOS, Windows, and Linux. These are development targets, not a claim
that every platform or native input backend is currently released. The existing
macOS download and editor screenshot are current preview artifacts.

The refined launch hero uses the existing Warband Command native render with a
CSS perspective tilt. Its screenshot is unchanged; the hero removes layout tabs,
preview captions, and secondary calls to action. Both landing URLs retain
platform development targets and the same accessible email form.
