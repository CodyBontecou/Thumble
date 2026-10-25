# Thumble read-only inspection

Connect https://thumble.io/mcp with OAuth authorization code + S256 PKCE. This package uses the public thumble-chatgpt client and requests identity, refresh access and profiles:read, devices:read, deliveries:read. All authentication endpoints and the resource audience use thumble.io.

Inspect your saved controller profiles, schema, registered phones and existing delivery receipts. Controller generation, validation, saving and sending are disabled. No hosted tool sends gameplay input. Use the built-in ConsolePort controller and the separate paired Mac receiver for play. Pairing may be advertised by the server, but is outside this package's base scopes and requires a separately approved flow plus an explicitly shared live receiver.

Sign in with an email code, Google or Apple and review consent. An empty profile/device list is valid for a new account. Only read a profile ID actually returned by your library, and only query a delivery receipt with a real existing ID. A rendered receipt confirms phone rendering, not Mac input or game bindings.

The phone app is an early public TestFlight beta at https://testflight.apple.com/join/kxwHv4qW. Reviewer access instructions belong in the private portal fields; no tokens, passwords or private account credentials are included in this package.

Website: https://thumble.io
Documentation: https://thumble.io/docs
Privacy: https://thumble.io/privacy
Terms: https://thumble.io/terms
Support: https://thumble.io/support
