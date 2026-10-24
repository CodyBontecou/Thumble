# Thumble for Gemini CLI

Inspect your saved Thumble phone controllers, registered phones and viewports, and existing delivery receipts from Gemini CLI. Connects directly to **https://thumble.io/mcp**.

## Install

Install [Gemini CLI](https://geminicli.com/docs/get-started/installation/), then run:

```sh
gemini extensions install https://github.com/CodyBontecou/thumble-gemini
```

Restart Gemini CLI and connect your account:

```text
/mcp auth thumble
/mcp list
```

Sign in to Thumble in the browser using email code, Google, or Apple, then review and allow access. The browser returns to a local callback on port **7777**; keep that port available. OAuth uses PKCE and a public native client: no client secret or API key is required. Tokens stay with Gemini CLI and can renew through the approved offline grant.

## Available tools

- `profile_schema`: inspect controller layout constraints.
- `list_profiles`: list your saved controllers and revisions.
- `get_profile`: read a saved layout.
- `list_devices`: list your registered phones and viewports.
- `delivery_status`: check an existing delivery receipt.

Try: “List my saved Thumble controllers” or “Show the latest revision of my controller.” An empty library or phone list is a valid result for a new account. Register a phone in Thumble for phone-specific results. The public iOS beta is available through [TestFlight](https://testflight.apple.com/join/kxwHv4qW).

## Permissions and limits

The extension requests `offline_access`, `profiles:read`, `devices:read`, and `deliveries:read`. It exposes only the five tools above. It cannot generate, save, deliver or activate layouts, manage phones, display pairing credentials, or send gameplay input. Use the built-in ConsolePort controller for play. A `rendered` receipt confirms phone rendering; it does not prove Mac input or game bindings. Live gameplay uses Thumble’s separate paired Mac receiver.

This is a Gemini CLI extension; it does not add a connector to the Gemini consumer app. Gallery discovery follows Google's automated crawler and does not imply Google endorsement.

[Website](https://thumble.io) · [Documentation](https://thumble.io/docs) · [Privacy](https://thumble.io/privacy) · [Terms](https://thumble.io/terms) · [Support](mailto:cody@isolated.tech)
