# Thumble CLI

Official read-only CLI for Thumble phone gamepad service discovery and account inspection. Node.js 22 or later; no dependencies.

Download the maintained script from [thumble.io](https://thumble.io/cli/thumble.mjs), then run:

```sh
node thumble.mjs config
node thumble.mjs sandbox
```

These commands need no account, credit card or API key. Sandbox records are fixed examples; they cannot access an account, phone, receiver or gameplay input.

For account reads, set `THUMBLE_ACCESS_TOKEN` through your environment using an existing consented OAuth connection. Do not put tokens in command arguments or commit them. The CLI only contacts `https://thumble.io`, rejects redirects and uses a 15-second timeout.

```sh
node thumble.mjs profiles
node thumble.mjs profile my-controller
node thumble.mjs profile my-controller 1
node thumble.mjs devices
node thumble.mjs delivery delivery-id
```

Required scopes: profiles:read, devices:read or deliveries:read for the corresponding command. Output is JSON; failures exit nonzero. On HTTP 429, wait for Retry-After. There is no automatic retry, login flow, persistent credential store, write command, or hardware control.

The npm package source is prepared as `thumble-cli`; registry publication is pending publisher authentication. The official download above works now. [Developer documentation](https://thumble.io/developers#cli).
