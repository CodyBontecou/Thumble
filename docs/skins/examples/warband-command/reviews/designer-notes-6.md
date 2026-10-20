# Warband Command1.0.2 — verified lossless icon interiors

Executed art-direction-3's bounded asset task. Colors, materials, icon placement/scale/fit, SVGs, geometry, input bindings, action-set mapping and authored ledger removal remain fixed. Parent owns clean-preview app/CLI presentation separately.

## Research and provenance

The installed Forever/classic data directories exist. Retrieved authoritative ladislav-zezula/CascLib into /tmp and compiled a read-only extractor. Storage initialization failed missing-file error2 at LoadCdnBuildFile for both installed products and a read-only mirror of the newer Data/wowf layout; no game data was modified and no local-client extraction is claimed. The failed local extraction does not establish the installed texture's dimensions.

Warcraft Wiki's imageinfo API identifies the same eight exact texture names, each as a64×64 original PNG. Retrieved each original URL and checked decoded format/dimensions. Initial HTTP responses used Cloudflare Polish's lossless recompression, so their byte hashes differed from the API originals. HTTP `Range: bytes=0-` requests bypassed recompression; all eight stored original PNGs now match the API SHA1 exactly. Metadata, verified byte hashes and actual response sizes are retained in sources/research/wiki-originals/imageinfo.json, sources/provenance.json and sources/research/exact-original-verification.json. The exact64 PNGs are also archived under sources/originals/. Copyright attribution remains Blizzard Entertainment; Wiki is the mirror, not the artwork creator. These are not verified Forever-specific exports.

The64 originals include an outer4px game border. The existing CDN56 assets already depict borderless artwork. Adopted the precise interior rectangle[4,4,60,60], producing56×56 PNGs with no resizing, sharpening, generative enhancement, repainting, new subject, or style changes. sources/restore-lossless-icons.py deterministically reproduces the crops and verifies API source hashes first. All previous PNGs and provenance plus the exact1.0.1 package are retained in reviews/archive-icons-1.0.1/. Original official JPEGs remain in sources/originals/.

This is lossless original-source artwork in the same56px interior size, replacing a JPEG-derived copy. It is not an increase in interior resolution, a256px source, or a promise of newly invented detail. Source contours and fine color boundaries look crisper because the JPEG degradation is absent. The crops contain different source pixels, not an interpolation of the old pixels. There is no increased-resolution claim.

## Proof the appearance is frozen

sources/research/appearance-invariants.json compares the archived1.0.1 package and new1.0.2 package. The complete compiled skin.json is byte-identical, SHA2568a961c414d1463326411488be4ce5291d2e9091508283e2aacd500701a59e09d in both. All four rasterized authored SVG assets are byte-identical. Native style tokens, glyph positions, banks, frames and layout compatibility are therefore unchanged. Only source icon bytes plus package version/media metadata differ. Preview fixture skin references were bumped to1.0.2; no app source was changed.

## Evidence and validation

- icon-source-comparison-6.png: initial original64 border versus previous56 source, illustrating why the border must not be squeezed into existing tiles.
- icon-interior-1x-before-after-6.png: old/lossless borderless assets at56px, all eight subjects.
- icon-interior-2x-before-after-6.png: diagnostic2× nearest-neighbor magnification of the same source interiors; not authored output or new detail.
- native-cluster-before-after-6.png: exact native-render screenshot crops from1.0.1 and1.0.2, arranged side-by-side with headings outside the crops. No controller pixels were edited.
- contact-sheet-6.png:64 native panels across all four banks, orientations, schemes and states, eight columns.
- landscape-dark-base-6.png: clean2× native controller image.

Strict validation valid/no warnings; quality100/100, zero errors/warnings. Reports validation-6.txt and quality-6.txt. Package build/warband-command-1.0.2.pocketpad SHA2561f53393e57dc7f93741b0067d6b36fdcdb7773f7170712aee8242642f1591782. Human approval remains pending; independent critique and deterministic QA are separate gates.
