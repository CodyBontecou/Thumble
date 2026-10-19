# Thumble Link v1

See [installation and usage](../Addons/ThumbleLink/README.md). This is a keyboard
snapshot integration, separate from the `wowForever` native-controller template.
The addon is in `Addons/ThumbleLink`; no addon-to-host network service is required.

## Wire contract

The clipboard format is `THUMBLELINK1:` followed by UTF-8 JSON. The importer also
accepts bare JSON. The complete input is bounded to 256 KiB, with at most 128
actions, four key alternatives per action, and 32 warnings. Duplicate JSON keys,
duplicate commands, invalid strings/identities, unsupported schemas, and unsupported
client interfaces are rejected before a profile mutation. Version 1 targets Forever
interface 16001 explicitly; a new client needs a tested adapter/contract update.

```json
{
  "schema": "thumble.wow-link",
  "version": 1,
  "client": { "flavor": "forever", "version": "1.60.1", "build": "99999", "interface": 16001 },
  "character": { "id": "Player-1234-00000001", "name": "Example", "realm": "Test Realm", "classTag": "WARRIOR" },
  "exportedAt": 1792310400,
  "actions": [
    { "command": "ACTIONBUTTON1", "label": "Heroic Strike", "keys": ["1"], "slot": 1, "kind": "spell", "actionID": 78, "iconFileID": 132282 }
  ],
  "warnings": []
}
```

`exportedAt` is Unix seconds. `slot`, `actionID`, `iconFileID`, and
`unavailableReason` are optional. No macro text or executable Lua is accepted.
Key alternatives retain WoW order; the importer uses the first supported keyboard
chord. `SHIFT`, `CTRL`, `ALT`, and `META` map to the existing shared Mac modifier
bits. WoW `DELETE` maps to forward delete, distinct from `BACKSPACE`.

## Export behavior

The addon reads each selected Blizzard button's resolved `action` slot and binding
command, and verifies each candidate key against its effective binding with
override bindings included. Missing metadata falls back to a bar/button label.
Export is blocked in combat and required API/build failures are explicit. Restricted
values are not inspected. Export never persists or changes protected game state.

The binding/slot pattern follows Blizzard's
[action button source](https://github.com/Gethe/wow-ui-source/blob/live/Interface/AddOns/Blizzard_ActionBar/Shared/ActionButton.lua).
The moving source branch is a reference, not a verified Forever client contract.
Native controller bindings are a separate interface; see Blizzard's
[Forever beta notes](https://us.forums.blizzard.com/en/wow/t/wow-forever-beta-development-notes-%E2%80%93-updated-october-15/2360696).

## Import and refresh

`ThumbleLinkSnapshot` is a bounded shared Codable value. `ThumbleLinkImport`
prepares the same ordinary configuration envelope for the Mac sheet and Swift CLI.
The normal profile authority owns persistence and phone synchronization. The CLI
uses the exported configuration revision for its atomic import; a concurrent change
fails instead of overwriting new edits. The Mac sheet rejects changed configurations
between review and import and registers the normal editor undo snapshot.

Profile identity is a deterministic, namespaced SHA-256-derived UUID based on game
flavor and character GUID. Button identity additionally includes the binding command,
so spell/rank replacements do not rearrange the phone. Matching an unrelated name or
an ID with missing integration metadata fails without replacing that setup.

The raw profile's `thumbleLink` field retains the last snapshot, import timestamp,
and known command labels through the existing forward-compatible metadata path.
No stored fields are added to the large shared profile/customization aggregates.
Each element's `defaultOutput` records its last imported binding baseline:

- If its current output equals that baseline, refresh updates it.
- If the user changed the output or label, refresh preserves the edit and reports it.
- Missing/unsupported bindings clear unchanged imported outputs.
- Previously deleted controls stay deleted; newly discovered bound commands get
  new controls. This applies independently to existing orientation layouts.

Refresh is scoped to one character setup, preserves unrelated controls and setup
metadata, and leaves the existing default setup selected as default. Mac imports
select the imported setup; CLI `--no-select` preserves selection.

## Verification

```sh
python3 scripts/verify-thumble-link.py --lua /path/to/lua
python3 scripts/verify-thumble-link-cli.py /path/to/packaged/bin
xcodebuild test -project Thumble.xcodeproj -scheme ThumbleTests \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ThumbleCLITests/ThumbleLinkTests CODE_SIGNING_ALLOWED=NO
./scripts/verify-stack-safety.sh
```

The Lua harness runs the real exporter and slash-command window with mocked APIs;
its output must match the fixture decoded by Swift. Swift tests cover validation,
keyboard conversion, profile construction, alternate binding selection, refresh,
manual edits, deletion, clearing stale outputs, name conflicts, and concurrent edits.
Stack regression coverage imports and refreshes a maximum-size 128-action snapshot
on a 512 KiB thread, with separate inline-size budgets.

Live acceptance remains: install in the supported Forever build, export main/extra
bars and utility actions, review on Mac, pair an iPhone, and verify actual keys,
modifiers, holds/releases, orientation changes, rebinding refreshes, and page/form
label limitations. No live WoW recognition or gameplay result is implied by mocks.
