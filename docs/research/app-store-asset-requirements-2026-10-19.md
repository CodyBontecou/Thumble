# Apple App Store asset requirements

Verified against current first-party Apple documentation on October 19, 2026. These are requirements and platform boundaries for the Thumble asset plan, not evidence that Thumble has an approved App Store record.

## Screenshots

Apple accepts 1–10 screenshots per device size, in JPEG/JPG/PNG, without transparency or alpha channels. Mac screenshots require 16:10 at 1280 × 800, 1440 × 900, 2560 × 1600, or 2880 × 1800. If Thumble pursues a native Mac App Store release, use 2880 × 1800 for that listing's production master (a planning choice).

Apple's current required-device section specifies at least one iPhone Dynamic Island medium-display screenshot: 1179 × 2556 or 1206 × 2622 portrait, or landscape reversals. Its table also accepts large Dynamic Island images at 1260 × 2736, 1290 × 2796, or 1320 × 2868, with landscape reversals. iPad support requires a 13-inch screenshot. Do not create phone screenshots for a Mac-only product. [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications).

## Headers and search creative

| Placement | Dimensions | Format |
| --- | --- | --- |
| Dedicated product page header | 3840 × 1646, 21:9 | JPEG/JPG/PNG |
| Dedicated search image | 1920 × 1280 minimum; 3840 × 2560 maximum, 3:2 | JPEG/JPG/PNG |
| Universal header/search image | 5244 × 2950, 16:9 | PNG |

All must be opaque, without alpha channels. Dedicated header/search videos use the corresponding dimensions above, 30 or 60 fps, 5–30 seconds, MOV/M4V/MP4. [Creative asset specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications).

**Platform boundary:** Apple explicitly makes these optional creative assets available to iOS/iPadOS apps running on iOS 27/iPadOS 27 or later. They are separate from screenshots, previews, purchase/subscription images, and editorial-requested promotional artwork. Do not present these as native Mac App Store upload slots. A universal asset can serve both header and search; dedicated variants are also supported. Assets can be approved independently through Asset Library, and approved assets can update a live version without a new app version. [Manage creative assets](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-your-app-store-assets/).

## Composition rules

Use one clear idea, current app visuals, and a center-safe focal point. Any text should be a short localized phrase that enhances the image. Preview cropping across devices/orientations in App Store Connect and use safe areas in Apple's actual templates; do not invent universal pixel insets. Headers should engage someone new to the app. Search creative should make the purpose obvious and may show the interface. Maintain visual continuity across placements. Exclude prices, discounts, website URLs, copyright symbols, other marketplace references, and unverified recognition. Store imagery must be appropriate for a 4+ audience. Apple provides Figma, Photoshop, Pixelmator, and Sketch template links. [Asset best practices and templates](https://developer.apple.com/app-store/asset-best-practices/).

## Testing and targeted pages

Product Page Optimization is documented for iOS/iPadOS, with up to three treatments of icons/screenshots/previews, shown on iOS/iPadOS 15+. The app must be Ready for Distribution; custom product pages cannot run PPO tests. A native Mac plan should not promise randomized App Store PPO tests. [PPO overview](https://developer.apple.com/help/app-store-connect/create-product-page-optimization-tests/overview-of-product-page-optimization/).

Custom product pages are also documented for iOS/iPadOS 15+, with up to 70 per app, localizable screenshots/previews/promotional text/keywords, unique links, and approval before display. Analytics require five first-time downloads. App deep links require iOS/iPadOS 18+. Treat CPP as a future mobile option rather than a native Mac launch dependency. [Configure custom product pages](https://developer.apple.com/help/app-store-connect/create-custom-product-pages/configure-multiple-product-page-versions/).

## Editorial and external promotional imagery

Editorial promotion is a separate workflow: nominate a launch/content/enhancement through App Store Connect, ideally at least three weeks before the target date. Up to five supplemental URLs can include art assets. Selection is discretionary, and editorial-requested artwork must follow the supplied request/templates; the public creative-header dimensions do not establish editorial upload requirements. In-App Events are available only for iPhone/iPad apps. [Featuring nominations](https://developer.apple.com/help/app-store-connect/manage-featuring-nominations/nominate-your-app-for-featuring/).

For website, social, press, and other external promotional images, Apple provides a Mac App Store badge and device bezels. Use supplied localized badge artwork; one badge per layout, subordinate to the main message, unchanged/unangled/unanimated. Standard minimum onscreen height is 40 px with clear space one quarter of badge height. Use Apple-provided bezels for supported current-generation devices. These rules apply to external marketing; they do not turn a social banner into a required App Store upload. [Marketing resources and identity guidelines](https://developer.apple.com/app-store/marketing/guidelines/).

## Practical implication for Thumble

Thumble has an iPhone app and a directly distributed Mac companion, as described in the [repository README](../../README.md). Prioritize iPhone screenshots and an external promotion kit that explains the Mac requirement. Prepare the optional iOS 27 header/search deliverables for that mobile listing. A future native Mac App Store listing would need its own Mac captures; it cannot reuse the mobile header placement assumptions. Keep editorial placement conditional on Apple's selection and requested specification.
