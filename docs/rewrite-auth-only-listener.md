# Explicit stable auth-only listener startup

Choose a persistent host identity and a fixed LAN address/port through the local agent or CLI:

```sh
thumble-rewrite identity initialize --identity-dir /absolute/private/identity
thumble-rewrite service start --identity-dir /absolute/private/identity --listen-address 192.168.1.20:27183 --advertise-host 192.168.1.20 --runtime-dir /absolute/private/runtime
```

`--listen-address` requires an explicit IP address and nonzero port. `--advertise-host` is an explicit concrete phone-reachable host; wildcard advertisements are rejected. Startup never guesses the LAN interface or chooses a replacement port. Binding `0.0.0.0:27183` is permitted only when explicitly requested; the advertisement must still be concrete. A persistent identity directory is required. Protect that directory separately from disposable runtime state.

This starts pinned TLS and the existing authenticated UDP input endpoint with enrollment **closed** and no pairing offer. It does not activate a controller or authorize a phone. The default startup has no network listener. Physical output remains a separate `--output macos-hid --allow-physical-output` opt-in; `--keep-saved-controller-ready` may be added separately and still requires an explicit saved-profile activation.

A new phone still needs an explicit `pairing open --reveal-secret` (and optionally QR export) to open the bounded enrollment window. Existing `pairing listen --reveal-secret` retains its original bind-and-open behavior. Existing trusted phones can perform the pinned hello-only authority resolution and then unchanged credential authentication after a host restart. The saved host/port and certificate pin must still match; changed addresses, ports or identity require explicit operator correction/new pairing. This is not network discovery, port forwarding, background login startup or a permission grant.

For a running persistent host, explicitly switch to auth-only mode with:

```sh
thumble-rewrite pairing listen-authorized --bind-address 192.168.1.20:27183 --advertise-host 192.168.1.20 --runtime-dir /absolute/private/runtime
```

That command closes any current enrollment window, replaces the listener and returns no offer. It does not require or accept `--reveal-secret`. A valid replacement that fails to bind leaves enrollment closed and the old listener stopped. Invalid command fields fail validation before changing policy.

Service `start`/`run` and internal detached startup propagate the exact explicit options. An already running service refuses changed startup options with `service_launch_options_restart_required`; stop/restart it explicitly. A startup bind/identity failure is reported using a bounded fixed error, never publishes a new ready endpoint, and closes/reaps the native configuration, input and pairing children before returning. No port fallback or automatic enrollment occurs.

Headless tests use synthetic loopback peers: same-port/pin/credential restart, current role-3 authority discovery and normal authentication, stale enrollment-proof rejection, default no-network startup, explicit closed-window transition, and child ownership rollback after failed bind/identity startup. They create no OS input device and make no claim about firewall configuration or real LAN reachability.
