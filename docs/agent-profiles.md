# Agent-designed controller profiles

The local MCP server exposes pairing and configuration: `show_pairing_code`, `profile_schema`, `list_profiles`, `get_profile`, `validate_profile`, `save_profile`, `activate_profile`, `controller_status`, and `agent_connection_check`. There is no tool for pressing a button, moving a stick, running a macro, or calling into the game. The agent creates declarative JSON; the human supplies all gameplay input.

For pairing in chat, run the updated receiver and call `show_pairing_code` with `{}`. Forward its native MCP `image/png` content inline so the player can scan it in **Connect Mac** on the same Wi-Fi. The tool reads the current code without opening a window or disconnecting a phone. Codes expire within two minutes; call again for the current image. Client support determines whether returned images appear inline. A text-only client can use **Pair phone…** in the receiver menu instead. Restart the MCP connection after updating its tool inventory. For ChatGPT’s hosted MCP, opt in with **Pair through ChatGPT…** in the updated receiver, sign in to the same Thumble account, and approve QR sharing. See [hosted pairing](hosted-mcp.md#pair-a-mac-from-chatgpt). The local tool still works without cloud sign-in.

## Recording workflow

1. Run the newly built Thumble Receiver and open the updated app on the phone. Both must be on the same Wi-Fi. Pair with the receiver's QR code or pairing link.
2. Connect the MCP server below to your agent. This machine already has a Codex registration named `tapping-profiles`.
3. Ask: “Make me a Warrior layout. Big Charge and Execute buttons under my right thumb, movement on the left, a smaller camera stick, and Chat up top. Save it and activate it on my paired phone.”
4. The agent reads the schema and revisions, validates a whole candidate, saves it, activates that saved revision, and checks `controller_status`. It can claim delivery only when status says `acknowledged`. If the phone is offline, activation is queued until it reconnects.
5. Record yourself playing. The included Warrior example labels gamepad X as Charge, Y as Execute, View as Chat, A as Jump, and B as Target. Configure these actions in ConsolePort before the take; these labels do not establish bindings.

`examples/profiles/warrior.json` is a complete starting point. Ask for subsequent changes in plain language (“move Execute lower”, “make both action buttons 20% larger”). The model edits the JSON through the same tools; no model API key is needed by the server itself.

## Connect an agent

Node 22+ is required. MCP uses newline-delimited JSON-RPC over local stdio, with no network listener or additional runtime dependency.

```sh
codex mcp add tapping-profiles -- node /Users/codybontecou/dev/tapping/packages/profile-tools/src/server.js
```

For other MCP clients:

```json
{
  "mcpServers": {
    "tapping-profiles": {
      "command": "node",
      "args": ["/Users/codybontecou/dev/tapping/packages/profile-tools/src/server.js"]
    }
  }
}
```

Refresh the client's MCP connection after registration. In a chat whose tool inventory has not refreshed yet, the same API is available through the shell:

```sh
node tools/profile.mjs list_profiles < /dev/null
node tools/profile.mjs get_profile <<'JSON'
{"id":"warrior"}
JSON
```

`tools/profile.mjs` takes a tool name and an arguments JSON object on stdin. It uses the exact same validation and store as MCP. `save_profile` accepts `{profile, expectedRevision}`; 0 creates a new ID. `activate_profile` accepts `{id, profileRevision, expectedActivationRevision}`; use 0 when nothing has been activated yet. Never resolve a conflict by blindly retrying: read the latest revision and reconcile the edit.

## Storage and delivery

The default store is `~/Library/Application Support/Tapping/profiles`. `TAPPING_PROFILE_DIR` overrides it; set the same absolute path in the receiver's environment and MCP server's environment when testing. The app always gets its layout from the paired receiver, so a bundled phone release works without Metro.

The store keeps one current saved revision per profile and an independent snapshot of the active revision. Saving an edit preserves the active snapshot until explicitly activated. Writes use an exclusive directory lock, a synced temporary file, and atomic rename. Concurrent agents cannot overwrite the same saved revision or activation. A crash can leave `write.lock`; after confirming no writer is running, remove that directory to recover. Keep a backup of `store.json` for historical revisions beyond the active snapshot.

A utility queue in the receiver polls for changes every 250 ms; file reads do not run on the HID/watchdog queue. Activation releases HID input, invalidates old freshness leases, and sends a `layout` frame over the pinned TLS session. The phone validates it again, renders it, replaces touch ownership, and acknowledges its revision. Only then does the receiver issue a fresh lease and accept neutral recovery followed by input for that revision. Late input and acknowledgements from superseded layouts cannot activate an old mapping.

The receiver publishes a small status file once per second and on activation/acknowledgement. `controller_status` treats it as stale after five seconds. “Acknowledged” confirms the phone's renderer committed that revision; it is not evidence of WoW spell bindings, game compatibility, or measured touch latency.

Disconnect returns the phone to its built-in practice layout. Reconnecting receives the saved active profile, including after receiver restart. Profiles are saved on the Mac; the phone has no separate offline profile library yet.

## Verification

```sh
npm test
npm run check
npm run lint --workspace @tapping/mobile
npm run typecheck --workspace @tapping/mobile
```

The opt-in native integration test uses a private invitation export and an isolated store. It sends only neutral input:

```sh
TAPPING_PROFILE_DIR="$PWD/build/profile-qa" \
TAPPING_INVITATION_FILE=/private/tmp/tapping-profile-qa-invitation \
  'build/Thumble Receiver.app/Contents/MacOS/thumble-receiver'
# In another terminal:
node tools/test-profile-receiver.mjs /private/tmp/tapping-profile-qa-invitation "$PWD/build/profile-qa"
```

Do not expose the invitation export; it contains a temporary pairing capability. The updated phone native module accepts layout messages up to 64 KiB, while phone-to-receiver input remains bounded at 4 KiB. Native receiver and phone builds must both be updated for live layouts. Legacy protocol-v1 phones can use the default layout only; custom activation tells them to update.

## Phone profile picker

Open **Thumble icon → Profiles** while connected to the Mac. The list comes from the same saved profile store used by MCP. Tap a profile to activate it, then tap Done to return to the controller. The selected label follows the rendered phone layout; switching completes only after its matching activation revision is rendered and the receiver acknowledges fresh neutral recovery. This releases held controls and changes no WoW bindings.

The paired WebSocket exposes `profiles-list` and `profile-select`; the phone cannot submit profile bodies. Selection includes the listed profile revision and expected activation revision. The receiver's `ProfileCatalog` uses the agent store's `write.lock` directory and atomic file replacement, rejects stale revisions, and keeps disk operations off the input/watchdog queue. A changed list shows an error with Refresh; disconnected phones and older receivers show a clear connection/update message. No separate offline profile library is created.

The native bridge regression is `node tools/test-profile-catalog.mjs` (macOS with Xcode CLI tools). It checks the shared lock, conflicting revisions, unknown IDs, boolean revision rejection and Node reading a Swift-written activation. `npm test` also covers correlated list replies, invalid catalogs, disconnect cancellation and selection waiting for render plus neutral acknowledgement.

## Check the agent from the phone

Open **Thumble menu → Connect your AI**, share the request with your Mac agent, and have it call `agent_connection_check` with the exact displayed code. Then tap **Check connection** on the phone within ten minutes. The receiver returns the fresh marker through the authenticated profile catalog, proving that the agent and receiver share the profile store. The tool uses the existing atomic transaction/lock and changes no profile, activation or bindings. A recorded tool response alone is not phone confirmation. Refresh MCP after updating the server to discover the new tool.

**Getting started → Make your first layout** prepares a persistent request with a unique profile ID and preferences. Share it with the same agent, then check layout delivery on the phone. Layout generation uses the existing profile and character tools; the phone does not embed an LLM or send character data to a new service.
