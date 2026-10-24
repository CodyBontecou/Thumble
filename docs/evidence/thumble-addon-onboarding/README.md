# Thumble addon installation copy — October 24, 2026

Website landing page, setup guide and support now mention the Thumble companion addon. The guide at https://thumble.io/docs#thumble-addon explains CurseForge client selection, Get More Addons, searching Thumble (project 1763832), installing a compatible version, enabling Thumble and ConsolePort, updating through My Addons, and /thumble discovery. It distinguishes gamepad recovery from ConsolePort's binding role. The public listing URL was derived from the project's own Project Page link.

CurseForge still showed Processing and a new-project approval notice when checked. Copy therefore states that approval is pending, identifies the initial Classic Era 1.15.9 scope, and allows players to continue with ConsolePort. It does not promise a public download or support for untested clients.

The mobile welcome and onboarding hub mention the recommended addon. The existing addon preparation stage has separate ConsolePort and Thumble cards, install/enable instructions, a website guide link and shared setup steps for the Mac. The existing ConsolePort completion check remains the prerequisite; the recommended addon does not block setup while awaiting approval.

Validation: 219 unit tests passed; mobile lint and typecheck passed; Release iOS and Android builds succeeded with AI controller generation disabled. Both installed as in-place updates on the connected iPhone 13 Pro Max and Pixel 7. App data was retained. Website local links/anchors checked across 12 HTML files, and responsive overflow checks passed at 1280px and 390px. Final site verified live in the browser.

The isolated simulator used com.thumble.wowsetupqa and a receiver linked to GamepadStub.c, which discards input and creates no HID. The existing fresh-install journey passed. The addon instructions were recorded live and replayed using .argent/e2e/thumble-addon-instructions.yaml with its paired/addon-stage prerequisite. An initial replay stopped after revealing the card heading but before scrolling to its guide button; the final test explicitly scrolls to each target and passes. No gameplay confirmations were checked, no live game input was emitted, and no pairing capability was saved in the test YAML or evidence.

Video: .argent/recordings/screen-recording-2C25402F-F87F-46EA-A615-A1A9C0689EC6-1792868588229.mp4. It captures the scroll to the new addon card. Screenshots: ios-addon-guide.png and website-live.png.

Website deployment: https://e50c0af6.pocketpad-site.pages.dev (existing pocketpad-site production/main). Canonical source remains /Users/codybontecou/dev/thumble/Website; hashes were checked before synchronizing the four changed files.
