# Declutter revision 1.0.1

The user requested removal of the passive bank reference and app toolbar from the image. The source artwork now omits all ledger panels, text, input keys and miniature overlays in portrait/landscape and light/dark. Native modifier banks, HOLD/HELD labels and interactive controls retain their existing behavior and geometry.

The clean native-renderer image is `landscape-dark-base-5.png`, opened in Codex and at http://127.0.0.1:8175/landscape-dark-base-5.png. It renders the exact 1.0.1 package without runtime toolbar chrome. It is a native controller render, not a screenshot edited to erase controls. The live simulator at port3200 still shows the previous 1.0.0 installed setup and its normal offline toolbar; app runtime policy has not changed.

Frozen review sheet: `contact-sheet-5.png` (64 frames). Package: `../build/warband-command-1.0.1.pocketpad`, SHA-256 `d36d38ae724063f4cd53e7ccbaa086133a38bdec44d4c2145d226b63ac177fda`. Exact image/sheet hashes are in `review-hashes.json`. Previous 1.0.0 package remains in `archive-ledger-v1/`.

Required stack-safety verification passed; log `/tmp/thumble-warband-declutter-stack-safety.log`. Human approval remains pending, with no publication, catalog edits or app-source changes.
