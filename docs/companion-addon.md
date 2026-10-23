# Thumble Bridge companion addon

Thumble Bridge exports a character's learned spells and current bindings, accepts a JSON plan from the local profile tools, and lets the player review and apply it outside combat. It configures bindings only. Every gameplay button press comes from the player.

## Install

```sh
node tools/install-wow-addon.mjs '/Applications/World of Warcraft/_classic_era_'
```

Choose the actual client directory. The installer backs up an existing Thumble Bridge installation, leaves other addons alone, and prints the destination. Restart the client when installing a new addon; `/reload` is sufficient for updates. Enable the addon and open `/thumblebridge` (or `/tbbridge`). ConsolePort is optional.

## Character to phone workflow

1. Click **Export character**. Copy the selected JSON and pass it to `import_character`. The export includes character identity, learned spells, current binding scope, action page, action slots, gamepad modifiers, base bindings and effective overrides.
2. Read the saved phone profile and call `propose_bindings` with its ID/revision and the snapshot ID. Without explicit intents, the tool matches labels to learned spell names and known utility actions. Unknown spells and ambiguous ranks remain unresolved. Explicit intents can select a learned `spellId` or a whitelisted utility `action` for a `controlId`.
3. Paste the returned `copyToAddon` JSON into the addon and click **Review pasted plan**. Check the old and proposed bindings and the account/character scope warning.
4. The player clicks **Apply reviewed changes** outside combat. The addon repeats validation, changes only the proposed unmodified gamepad keys, preserves existing keyboard bindings, saves the current scope and retains previous bindings for **Restore last bindings**.
5. Click **Export result** after ConsolePort has refreshed. This rechecks both the base and effective bindings. Copy the JSON to `import_binding_result`. A pending or mismatched result cannot confirm a plan.
6. Call `sync_binding_labels` with the plan ID and unchanged saved profile revision. This saves a new profile revision without activating it. Call `activate_profile` explicitly, then check `controller_status` for the phone acknowledgement before recording.

Example proposal arguments (use IDs and revisions returned by your own exports):

```json
{
  "snapshotId": "EXPORTED_SNAPSHOT_ID",
  "profileId": "warrior",
  "profileRevision": 1,
  "intents": [
    { "controlId": "charge", "spellId": 78 },
    { "controlId": "chat", "action": "OPENCHAT", "label": "Chat" }
  ]
}
```

Spell 78 is only an example for a character that has learned Heroic Strike. Control IDs identify existing phone controls; they do not force their displayed labels to remain unchanged.

The MCP server exposes nine character/plan/result/mirror tools alongside the seven existing profile tools. Refresh the MCP connection after updating the server. The same API is available through `node tools/profile.mjs TOOL < arguments.json`.

## Mirror ConsolePort on the phone

The character export also includes `consolePortLayout` when ConsolePort's visible `CPB_` button frames are available. It reads each frame's position and its eight modifier states, resolves action slots against the current page, and exports spell/item IDs. This is read-only; it never clicks or modifies a ConsolePort frame.

`mirror_consoleport` takes `{ snapshotId, sourceProfileId, sourceProfileRevision, profileId, expectedRevision }`. It saves a separate phone profile with the same relative button clusters, spell/item artwork, utility artwork and modifier labels. The source profile supplies stick mappings and utility buttons without visible ConsolePort frames. Its current movement/camera assignment is preserved. Activate the returned revision explicitly to deliver it.

WoW artwork names are resolved from public Wowhead spell/item metadata; the phone loads images from the fixed WoW icon CDN. Lookup or download failures retain the text label. ConsolePort utility artwork is bundled unmodified with its Artistic License 2.0 notice in `apps/mobile/assets/consoleport`. Empty action slots remain empty. Holding a modifier changes presentation based on the phone's actual held outputs, while the modifier button itself uses ConsolePort's complementary state.

This mirrors the exported context, not a continuously streamed game HUD: export again after changing bindings, action pages, stance or ConsolePort geometry. Cooldowns, proc glows, live target state and automatic in-game page updates are not transmitted. A visual snapshot does not apply a binding plan.

On October 23 the user clarified that both horizontal and vertical directions were reversed on both sticks; the earlier output swap was a misunderstanding. Revision 4 restores `move` to `[lx, ly]` and `look` to `[rx, ry]`, initially with `invertX: true` and `invertY: true` on both mappings. The player subsequently reported horizontal reversal; revision 5 removes horizontal inversion (`invertX: false`) while retaining `invertY: true`, and the phone acknowledged activation 6. These optional boolean settings affect only the profile's output; the visual cap follows the finger and the shared HID codec is unchanged. Both the Warrior source and `consoleport-bonteq` carry this correction.

The first mirror compressed the full HUD into a narrow strip. The revised layout scales the left and right diamonds separately, keeps their relative button order, and reserves distinct space for shoulders, triggers, sticks and Chat. A geometry regression checks non-overlapping touch regions and targets of at least 44 points on a 780 × 280 canvas. A touch regression checks all four directions on both inverted sticks, independent output assignment, finger-following visuals and neutral release.

The corrected renderer passed a Release simulator check over an isolated TLS preview receiver that discards all input, including held modifier changes, stick drag/release and artwork rendering. The Release build installed on the iPhone 13 Pro Max with zero errors and three toolchain warnings. The phone acknowledged profile revision 4 / activation 5 and the player approved the layout; subsequent physical testing found horizontal reversal and an outside-circle input cutoff. Horizontal calibration is corrected at revision 5 / activation 6; outside-circle verification remains open. See the updated [preview](../.argent/recordings/consoleport-direction-preview.mp4) and [still](evidence/consoleport-direction-preview.png). The preview is UI verification, not gameplay or latency evidence.

## Disk export option

After clicking **Export character** or **Export result**, `/reload` or logout flushes the selected JSON into the character's SavedVariables file. `read_addon_export` accepts `savedVariablesPath` ending in `SavedVariables/ThumbleBridge.lua` and `exportKind` equal to `character` or `result`. It extracts only the saved JSON string without executing Lua. It does not write game files or provide live telemetry.

The addon does not connect directly to MCP or poll arbitrary files. The handoff is explicit copy/paste or a flushed disk export. Names and skill bindings reach the phone only after a verified result and explicit profile activation.

## Validation and limits

Plans contain learned active spells or a small utility-action whitelist. Macros, arbitrary Lua, keyboard bindings, modified keys, reserved modifier/cursor buttons and unknown effective overrides are rejected. Character, spec, build, scope, action page, slots, modifiers and bindings must still match the export. Combat rejects changes immediately; nothing is queued to apply later.

ConsolePort action-bar proxies are recognized only when the installed manager and matching controller frame confirm their identity. Writes use native binding APIs with ConsolePort's binding context; the helper that can clear a command's other bindings is deliberately avoided. ConsolePort may refresh asynchronously for both action-bar proxies and ordinary utility bindings. An effective route that still matches the validated old route may remain pending until **Export result** verifies the new route. Unexpected routes trigger rollback and include the observed route in the error. A receipt reports a point-in-time addon observation, not continuous or cryptographically authenticated game state.

Direct spell bindings use the client's localized spell name. They do not rewrite action bars or implement stance-specific layouts. Export again after character/context changes. Restore refuses a changed character, scope or binding map; on a native restore failure it reports the error rather than claiming success.

On October 23, 2026, Classic Era with ConsolePort 3.3.11 completed the round trip on the real level-1 warrior: character export, plan review, player Apply, verified receipt, label synchronization and phone acknowledgement. The confirmed routes were PAD3 → SPELL Heroic Strike, PAD4 → SPELL Perception, and PADBACK → OPENCHAT. ConsolePort's old routes cleared after a UI reload; Export result then verified all three. The canonical Warrior profile was saved at revision 2. The running test receiver used `/tmp/tapping-udp-profiles`; the same confirmed profile was saved and activated there at revision 1, and its connected phone acknowledged activation 1. The Forever client has an installation but has not been verified running this addon.

## Tests

```sh
npm test
npm run test:addon
```

Addon tests require Lua 5.1 (`TAPPING_LUA=/path/to/lua` or an available `lua5.1`/`lua`). They cover JSON parsing, JavaScript-generated plans through Lua review, stale context, combat rejection with zero writes, preservation of keyboard bindings, rollback, ConsolePort proxy refresh, legacy/modern spellbooks, receipt verification and UI review invalidation. Automated tests supplement the real client/player verification described above.
