# Starter configuration v1

An explicit first-run command initializes an empty headless configuration authority with one editable owned-v5 gamepad profile. It requires no desktop installation, source fixture, exported file or external assets. Existing configuration is never replaced.

```sh
thumble-rewrite service start --runtime-dir /absolute/private/runtime --json
thumble-rewrite configuration initialize-starter \
  --runtime-dir /absolute/private/runtime \
  --operation-id first-controller \
  --expected-revision 0 \
  --profile-id e1000000-0000-0000-0000-000000000001 \
  --name 'My controller' --json
thumble-rewrite configuration list --runtime-dir /absolute/private/runtime --json
```

Use a fresh UUID chosen by the user or their agent, plus a stable operation ID. The reply is the normal durable configuration receipt, including resulting revision and source content hash. An exact retry recovers that receipt after service restart or later edits. Reusing the operation ID with a different intent is rejected. Any other attempt after initialization returns a revision conflict. The command accepts only expected revision `0`; there is no overwrite option.

MCP exposes `configuration_initialize_starter` only when the server was launched with `--allow-configuration-write`. Its exact arguments are `operationId`, `expectedRevision: "0"`, `profileId`, and `name`. Read-only MCP sessions cannot discover or call it. Both supported MCP protocol eras use the same operation and durable receipt.

The production starter has 18 separate, nonoverlapping controls: four D-pad directions, four face buttons, two shoulders, two stick-click buttons, Select/Start, movement and camera sticks, and independent left/right triggers. Sticks use the retained standard radial dead zone 0.12 with sensitivity 1; triggers use continuous vertical input with dead zone 0.03. No pointer mouse-look, keyboard bindings, resources, secrets, or linked desktop state are generated. The camera control is the right gamepad stick.

The source is validated by the existing owned-v5 codec and stored through the sole configuration repository as an owned authority. Explicit geometry projects through the same saved-controller path used by phone delivery. The starter selects its saved active/default profile. This is saved configuration selection only: receiver activation, phone pairing, OS device creation and physical output remain separate explicit operations. Capture and live-sync state are unaffected.

To use it, obtain the receipt/catalog revision and source hash, then explicitly activate the saved profile using the existing `receiver activate-saved` command and the current receiver CAS values. Physical output additionally requires the opt-in macOS backend and its allow flag. An initialization receipt does not establish signing, phone connectivity, gameplay compatibility, or physical acceptance.

Regression coverage projects all 18 actions over 42 bounded landscape viewports (including the minimum square boundary), verifies no overlap through the production projection, and checks exact timestamps beyond JavaScript's safe integer range. Real SQLite restart/replay tests preserve intervening edits. Independent Node clients exercise CLI and modern/legacy MCP against a recording-only service, including denied read-only access, conflict refusal, and inactive receiver status before/after restart.
