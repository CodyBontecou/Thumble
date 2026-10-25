# Thumble for Cline

Connect Cline directly to **https://thumble.io/mcp** to inspect saved Thumble controller layouts, registered phones and existing delivery receipts. No local Thumble server process is required.

## Install in Cline

Use a current Cline version with preregistered MCP OAuth client support. In Cline, open **MCP Servers → Configure → Configure MCP Servers**. Merge this entry into `mcpServers`, preserving your other servers:

```json
{
  "mcpServers": {
    "thumble": {
      "type": "streamableHttp",
      "url": "https://thumble.io/mcp",
      "oauthClient": { "clientId": "thumble-cline" },
      "disabled": false,
      "autoApprove": []
    }
  }
}
```

A copy is provided in [cline_mcp_settings.json](cline_mcp_settings.json). The client ID is public; no client secret or API key is needed. General-purpose dynamic client registration is restricted, so keep the `oauthClient` field.

Choose **Authenticate** for Thumble. Cline CLI users can run `cline mcp` and choose **Authorize OAuth** after merging the same config into `~/.cline/data/settings/cline_mcp_settings.json`. Sign in through Thumble using an email code, Google or Apple, review the consent screen, and allow access. The browser returns to `http://127.0.0.1:1456/mcp/oauth/callback`; keep port 1456 available. Native loopback port fallback may be supported by your client; hostname and path must match.

OAuth uses authorization code with S256 PKCE, explicit consent, audience-bound tokens and the approved read-only scopes. Persistent sign-in can renew through `offline_access`. Requested data permissions are `profiles:read`, `devices:read` and `deliveries:read`.

## Verify the connection

After authorization, confirm Cline shows Thumble's tools, then ask: **“List my saved Thumble controllers.”** Approve the `list_profiles` call when prompted. An empty list is valid for a new account. Try `profile_schema` to inspect layout constraints without creating data.

Read-only tools include `profile_schema`, `list_profiles`, `get_profile`, `list_devices` and `delivery_status`. The endpoint may advertise a separate `show_pairing_code` tool, but this Cline client has no pairing permission and must not invoke it. It cannot generate, save or send layouts, manage phones, or send gameplay input. A rendered delivery receipt only confirms phone rendering, not Mac input or game bindings.

To get phone-specific results, sign in to the [public Thumble iOS beta](https://testflight.apple.com/join/kxwHv4qW) with the same account and register your phone. Use the built-in ConsolePort controller for play; gameplay runs through Thumble's separate paired Mac receiver.

## Troubleshooting

- **Client registration fails:** use the exact public `oauthClient.clientId` above instead of dynamic registration.
- **Callback cannot connect:** keep port 1456 free, then retry Authenticate.
- **HTTP 401:** sign in or reauthorize through Cline's normal OAuth flow. Do not paste tokens into chat or GitHub issues.
- **Forbidden pairing call:** use only the approved read-only tools; pairing is outside this client's permissions.

[Website](https://thumble.io) · [Documentation](https://thumble.io/docs) · [Privacy](https://thumble.io/privacy) · [Terms](https://thumble.io/terms) · [Support](mailto:cody@isolated.tech)
