# Windows and Linux local receiver

`thumble-receiver` is a native Windows/Linux LAN receiver for the current iOS
app. It reuses `thumble-core` and `thumble-protocol`, including six-digit pairing,
trusted reconnects, complete profile delivery, UUID-based input v3, replay and
stale-generation rejection, and held-input expiry. It does not require the Mac
app, Swift, a cloud service, or a relay. The existing Mac host remains available
with its richer configuration/MCP tooling.

The receiver implements keyboard chords/sequences, relative mouse movement,
scrolling, and left/right/middle buttons. Windows uses `SendInput`; Linux uses a
virtual `uinput` keyboard/mouse that can be consumed by X11 and Wayland desktops.
The wire format retains its existing Mac physical key codes; the receiver maps
these to native scan/input codes. Command maps to Windows/Super, Option to Alt,
and Control to Ctrl. Bindings are physical keys, interpreted by the computer's
keyboard layout. Fn has no portable injection mapping and is rejected.

Virtual gamepad output, rumble, authenticated UDP, Mac launch targets, Mac skin
mutation, Swift configuration helpers, and the Mac MCP/control socket are not
implemented in this binary. Virtual gamepad status explicitly says unavailable,
and gamepad events fail rather than silently succeeding. Use keyboard/mouse
bindings. The iPhone automatically uses reliable WebSocket input because this
receiver does not advertise a realtime UDP token.

## Build and run

With Rust 1.88 or newer installed, from the repository root:

```sh
cargo build --locked --release --manifest-path Host/Cargo.toml -p thumble-receiver
```

On Windows, open PowerShell as your normal desktop user:

```powershell
.\Host\target\release\thumble-receiver.exe run
```

Allow the executable through Windows Defender Firewall on the private network
when prompted. If configuring rules manually, allow inbound TCP 8765 and UDP
5353 for this executable on your private network. Run as your normal user:
Windows restricts input into elevated applications and secure desktops through
UIPI. The receiver reports delivery failures; it does not bypass that boundary.

On Linux, enable `uinput` and grant your logged-in desktop user access once:

```sh
sudo modprobe uinput
sudo install -m 644 packaging/receiver/70-thumble-uinput.rules /etc/udev/rules.d/70-thumble-uinput.rules
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=misc --sysname-match=uinput
```

On distributions using systemd-logind, log out and back in if `/dev/uinput`
remains inaccessible. Persist module loading, if needed, with a distribution
configuration file under `/etc/modules-load.d/` containing `uinput`. The udev rule
allows synthetic input to the active local desktop user; it does not grant read
access to other input devices. Non-logind distributions need an equivalent
user-specific device ACL. Do not make `/dev/uinput` world writable.

Run the receiver as the desktop user, without sudo:

```sh
./Host/target/release/thumble-receiver run
```

Allow inbound TCP 8765 and multicast UDP 5353 on your trusted LAN firewall.
If the requested TCP port is occupied, choose `run --port 8766`. Discovery and
status advertise the actual bound port. `--port 0` chooses an available port.

Keep the computer and iPhone on the same reachable IPv4 LAN, enable iOS Local
Network access, and open the connection screen in Thumble. Smart Connect uses
the existing `_pocketpad._tcp` service and server identity TXT record. For manual
pairing, enter the printed `ws://<computer-ip>:8765` address and request pairing.
Then obtain the current six-digit code in another terminal:

```sh
thumble-receiver pairing-code
```

A pairing request rotates the code, so the initial startup code may have changed.
The phone must not use `localhost` or `127.0.0.1`: those addresses refer to the
phone itself. Guest-network/client isolation may prevent either discovery or
control. `run --no-bonjour` permits manual connection when multicast is blocked.
This release listens on IPv4 and advertises IPv4 addresses only; Apple-specific
AWDL/router-free peer-to-peer discovery is not available on these platforms.

Local LAN WebSockets retain the existing unencrypted protocol. Pair on a trusted
network; the receiver is not intended to be exposed directly to the internet.

## CLI and persistence

Run these commands using the same executable and desktop user:

```sh
thumble-receiver status
thumble-receiver pairing-code
thumble-receiver release-all
thumble-receiver stop
```

All return JSON. `status` includes connection state, LAN addresses, counters,
input mode, pending neutralization, last error, and honest gamepad readiness.
`release-all` retires active input sessions so queued pre-release frames cannot
restore a hold. The phone can reconnect afterward. `stop` and Ctrl+C release
input before the process exits; Linux also handles SIGTERM. Run in a terminal or
under your normal per-user process manager; no boot/system service is installed.

State lives under `%LOCALAPPDATA%\Thumble\ThumbleReceiver\data` on Windows and
`$XDG_DATA_HOME/thumblereceiver` (usually `~/.local/share/thumblereceiver`) on Linux.
`--state-dir <private-directory>` selects an explicit location and must be
repeated for the local commands. Do not share this directory: it contains
trusted reconnect credentials. Unix uses owner-only modes; Windows uses a
protected DACL granting the owner and SYSTEM access. A lifetime file lock prevents
multiple input owners. State writes are atomic and bounded. Corrupt existing
state causes startup to fail without replacing the identity.

Local CLI traffic uses a separate loopback-only TCP listener with a random
per-run credential in the protected runtime record. That credential is never
advertised over mDNS or sent to iOS. The CLI listener requires authentication
before dispatching any command, including status and stop.

The default profile is available immediately. To install a portable
`ConfigurationDocument` (the shared configuration shape containing `profiles`,
`activeProfileID`, `defaultProfileID`, and binding maps), stop the receiver first:

```sh
thumble-receiver import-configuration configuration.json
```

Import validates the complete document and preserves this computer's identity
and trusted clients. It does not accept a raw Mac backup envelope or a skin
package. The saved configuration is delivered to iOS on pairing/reconnect.

## Verification and acceptance

```sh
cargo test --locked --manifest-path Host/Cargo.toml -p thumble-receiver
cargo check --locked --manifest-path Host/Cargo.toml -p thumble-receiver --target x86_64-pc-windows-gnu
cargo check --locked --manifest-path Host/Cargo.toml -p thumble-receiver --target x86_64-unknown-linux-gnu
```

Automated coverage includes key translation, overlapping modifiers, partial
output failure cleanup, exclusive state ownership, corrupt-state preservation,
real executable/WebSocket pairing, profile delivery, unauthenticated-input
rejection, input expiry, disconnect, restart/trusted reconnect, and local-control
authentication/frame bounds. `run --no-input` verifies transport without creating
or injecting a native device. The Windows/Linux CI matrix runs the loopback
suite and produces native executable artifacts. Downloaded Linux artifacts need
`chmod +x thumble-receiver` before running.

Cross-compilation and loopback tests do not establish real desktop delivery.
Before treating a platform as release-ready, pair a real iPhone, type into a
normal desktop editor, hold two shortcuts sharing Ctrl and release each in turn,
move/drag/scroll/click, disconnect with keys held, and suspend/resume with keys
held. Verify trusted reconnect after restarting the receiver, and repeat Linux
checks on the target X11/Wayland desktop. Verify blocked elevated Windows input
reports a failure. Gamepad compatibility remains outside this receiver's scope.

Native API references: [Windows SendInput](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput),
[Linux uinput](https://docs.kernel.org/input/uinput.html), and
[mdns-sd](https://docs.rs/mdns-sd/0.13.11/mdns_sd/).

## Native delivery in GitHub Actions

The `Windows and Linux receiver` workflow runs the opt-in `native_delivery`
test in disposable native Windows/Linux runners. It starts the actual receiver
with input enabled, pairs a synthetic client using the iOS v3 wire codec, and
checks OS-observed key, modifier, mouse, wheel, and disconnect-release events.
Windows uses a dedicated foreground test window and its message handler. Linux
reads the receiver's own uinput event node; no other keyboard device is captured.
Evidence is uploaded as `native-delivery-<runner-os>` JSON and logs.

This is distinct from running the iOS app. An Actions pass proves receiver-to-OS
delivery with a protocol client. It does not establish phone networking, Local
Network permission, Bonjour discovery, touch interaction, or hardware behavior.
Windows delivery also requires a foreground desktop. If a hosted runner cannot
provide one, that native test fails explicitly; use an unlocked interactive
Windows runner/VM instead of treating the loopback tests as an equivalent pass.

To run the opt-in test manually in an isolated environment:

```sh
THUMBLE_NATIVE_EVIDENCE=native-evidence.json cargo test --manifest-path Host/Cargo.toml -p thumble-receiver --test native_delivery -- --ignored --nocapture
```

On Linux, the user must have access to `/dev/uinput` and read access to the
receiver's newly created `/dev/input/event*` node. The workflow installs a test
udev rule scoped to the exact `Thumble Keyboard and Mouse` device name. Do not
install that additional event-observer rule as part of a normal receiver setup.
