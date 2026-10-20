# Warband Command — independent visual critique 1

**Verdict: revise.** Reviewed the frozen `contact-sheet-2.png` (4320×3338; 64 panels), its full-resolution regional crops, all four `landscape-dark-*-2.png` normal renders, and `portrait-dark-base-2.png`. Source inspection was limited to explaining visible defects. No design source or package was changed.

## Pass 1 — composition

The ability artwork now supplies the primary visual emphasis. Both action diamonds read as abilities rather than a plastic gamepad shell. All four passive ledger panels remain visible across every action set and state; I found no ledger/native-control overlap. Portrait is independently arranged rather than a stretched landscape image. Utility controls and sticks are subordinate to the icon clusters. Portrait's generous middle separation follows the canonical touch geometry; changing that geometry is outside this review.

### C1 — major: portrait ledger omits the input correspondence

- **Affected panels:** all 32 portrait panels, light/dark, Base/LT/RT/LT+RT, all states.
- **Visible evidence:** each bank shows a 2×2 set of four icons while the playable face buttons form a diamond. Portrait has no A/X/B/Y labels or ordering key beside the miniatures. For example, portrait Base's top-left green axe means A, although A is the bottom of the playable diamond; a viewer must infer or memorize this relationship. Landscape at least includes `A X / B Y` under every bank. The portrait preview cannot independently explain what its reference cells mean.
- **Likely cause:** the shorter portrait ledger dropped the landscape ordering legend. The source SVG confirms that no portrait input key exists.
- **Correction:** identify every portrait reference cell with a readable input letter, or change each miniature layout into a labeled diamond that mirrors the playable cluster. A compact shared `A X / B Y` key is acceptable if it unambiguously applies to all four panels and stays legible at 1×. Preserve the 16 px artwork and at least 8 px clearance from neighboring native frames; do not hide any bank. A reviewer should be able to locate the A ability in each portrait bank without consulting documentation or the landscape layout.

## Pass 2 — material and craft

The restrained brass/cool bank accents, shallow sockets, and separate pale appearance establish a coherent command-board treatment. I found no copied hardware silhouette, conspicuous seams, stretched art, clipped legends, or bank-dependent geometry shifts. The eight small raster ability images have inherent source detail limits, but their silhouettes and colors remain recognizable at native tile size. The passive references read as miniatures rather than additional full-size touch controls.

### C2 — minor: current bank has no textual confirmation

- **Affected panels:** all LT, RT, and LT+RT normal panels in both orientations and appearances; also relevant when comparing every bank's pressed panels.
- **Visible evidence:** the ledger never marks one panel as current, both trigger capsules continue to say `HOLD`, and the identity of the selected bank is conveyed through thin tile/puck color and icon reassignment. In grayscale, identifying a bank requires comparing the miniature assignments against the playable tiles. This slows orientation to the modified surface.
- **Likely cause:** action-set selectors change `--bank` and icon assignments, but do not change a textual status legend.
- **Correction:** use native trigger legends such as `LT · HELD` / `RT · HELD` for held modifiers, or add an equally explicit native current-bank status. Keep the passive reference and all four headings visible. Base, LT, RT, and LT+RT should be distinguishable by readable text with color removed, with no capsule or touch geometry movement.

## Pass 3 — interaction and state

Utility capsules and sticks demonstrate a readable progression: normal filled face, pressed darker/inset face, active thicker bank boundary, and disabled subdued face. Disabled ability artwork is clearly muted while adjacent input tags remain visible. The native state matrix shows no position or size drift.

### C3 — major: actionable ability tiles lose the pressed/active distinction

- **Affected panels:** all 24 normal/pressed/active landscape panels and all 24 corresponding portrait panels; most evident in the light appearance and the Base bank.
- **Visible evidence:** in side-by-side native normal/pressed/active rows, the ability artwork and its apparent outer socket look almost unchanged even as R3 and camera show obvious state changes. The light Base A/X/Y tiles in particular retain the same bright art and dark square treatment in all three states. The active border is much less apparent on the very controls that are the redesign's focus. Disabled is distinct and is not the problem.
- **Likely cause:** the large centered artwork covers most of the fill and inset shadow. The 1.5 px normal → 2 px pressed edge change and narrow active boundary do not establish separate visual modes around the image; passive socket outlines further compete with native state edges.
- **Correction:** reserve a continuously visible native perimeter around the icon, reducing icon scale enough that it cannot cover the state frame. Deliver a visible 2 px pressure rim/inset treatment when pressed and a distinct continuous 3 px bank-colored active boundary, with the two states separable in grayscale. Keep at least 36 px identifiable artwork at 1×, stable image/legend centers, and the existing hit frames. Re-render a close comparison of normal/pressed/active ability clusters in both appearances before regenerating the full matrix. The distinction must survive the contact-sheet scale, not only a magnified source view.

## Originality / trade-dress check

The framing, ledger, typography, and materials read as a newly composed sparse command board. I found no console outline, copied Blizzard HUD border, proprietary controller glyph drawing, logo, rune system, or obvious tracing of the referenced hotbars. Ability artwork is identifiable Blizzard content; the project brief explicitly permits the existing eight attributed assets and records provenance. This review does not turn that provenance into a broader asset license.

## Required next evidence

Resolve C1 and C3, preserve this sheet/report, and produce a new immutable all-bank/all-state native sheet for the second independent critique. C2 is a concrete usability improvement and should be addressed in that same bounded pass. Strict validators and deterministic QA remain separate gates. Human approval remains pending.

**Highest priorities:** (1) native ability pressed/active feedback; (2) portrait miniature-to-input correspondence; (3) textual held-bank confirmation.
