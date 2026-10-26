# Thumble desktop receiver preview

Windows 10/11 x64 and Linux x64 receiver for the existing Thumble phone app. This
is a separate Python implementation of the Mac receiver's v3 LAN protocol. The
signed Swift macOS app continues to live in `apps/receiver`.

Implemented in the preview:

- Process-local TLS identity, SHA-256 certificate pin in a two-minute, single-use
  QR invitation, and one authenticated phone at a time.
- Native Xbox 360 output on Windows and a Linux uinput gamepad with matching
  buttons, sticks, triggers, and opposing D-pad cancellation.
- Monotonic 500 ms server leases, increasing sequences, 300 ms input watchdog,
  neutral recovery, two-second disconnect, bounded messages and client count.
  A separate output thread releases controls if the network loop stalls. No
  user-space watchdog can run while the entire OS is suspended; stale input is
  rejected and neutral recovery is required when execution resumes.
- Durable 30-minute demo with crash-conservative five-second reservations,
  phone usage mirroring, signed Ed25519 Pro grants, and explicit Resume.
  The entitlement public key and wire fields match the existing purchase service.
- A terminal QR, configurable LAN interface/port, single-instance data-directory
  lock, clean signal shutdown, explicit dry-run mode, and packaged-runtime test.
- Saved profile catalogs/selection, immutable cloud adoption, layout render
  acknowledgement, neutral recovery, and saved layout restore on reconnect.
  Activations pause play; resume controls explicitly after the layout is ready.
- Shared local-agent profile storage and receiver delivery status. Built-in
  profiles come from the same generated resource as the Mac and phone.
- Saved ConsolePort addon snapshot sync with all eight modifier layers, actual
  modifier assignments, character-specific profiles, and preserved geometry.
- Encrypted AES-GCM UDP input, with TLS control traffic and WSS fallback.
- Focus-checked, literal WoW chat delivery to an identified window. Windows uses
  targeted Unicode window messages; Linux uses xdotool on X11/XWayland.
- Native pairing/settings window, tray controls, per-user installation and
  optional start at sign-in. Closing the window retains the tray when available.
- Local MCP pairing PNG export with POSIX permissions or a protected Windows ACL,
  browser OAuth/PKCE sign-in, and explicit ten-minute ChatGPT QR sharing.
- Bounded, cached spell/item icon-name lookup, matching the Mac endpoint.

These builds are unsigned previews; production signing and an automatic update
service are separate release work. Existing phone copy still calls the computer “Mac”; **Connect Mac** also
scans this receiver's invitation. No mobile changes are needed for basic input.

## Run a CI artifact

Download the artifact for your OS from the **Desktop receiver** GitHub Actions
run. Windows includes a per-user setup executable; run it, complete the separate
gamepad driver setup below, and open **Thumble Receiver** from Start. Setup registers
the browser sign-in callback without administrator privileges. It does not install
the kernel driver. Uninstall through Windows Apps settings; your profiles and
purchase/demo records are retained.

For Linux, extract the archive and install the application for your user:

```sh
# Linux
tar -xzf Thumble-Receiver-0.1.0-linux-x64.tar.gz
./thumble-receiver/thumble-receiver --install-user
```

Open **Thumble Receiver** from the applications menu. The installer registers the
browser callback and adds `~/.local/bin/thumble-receiver`. It requires `xdg-utils`
and uses `${XDG_DATA_HOME:-~/.local/share}/thumble/receiver/0.1.0`. Run the installed
binary with `--uninstall-user` to remove the app while retaining receiver data.
Keep the bundle's `_internal` directory alongside the executable; libraries stay
replaceable and third-party licenses are included. SHA-256 checksums accompany
both platform packages.

The window shows the QR, current connection status, ChatGPT sharing controls,
ConsolePort folder selection, start-at-sign-in, and Wi-Fi interface selection.
**Restart here** releases controls before rebinding to a selected LAN address.
The tray includes pairing, sharing, disconnect, and quit actions. On desktops
without a tray, closing the window releases controls and exits.

For a terminal-only receiver, run the installed executable with
`--headless --address 192.168.1.20 --port 8765`. Portable bundles can register
browser sign-in with `--register-protocol`; normal installers already do this.

Use this computer's Wi-Fi IPv4 address. With no `--address`, the receiver selects
the default route's private IPv4 interface; specify it explicitly if a VPN or
multiple adapters select the wrong network. The phone must be on the same LAN.
Allow inbound TCP for the chosen port on the private network in the OS firewall.
No router port forwarding is needed. Omitting `--port` chooses an available port.

Scan the QR in Thumble's **Connect Mac** screen, then use **Start demo / Resume**.
The QR renews after expiry or disconnect. Ctrl+C releases the pad and exits.
Keep the QR private; do not capture it in CI logs or share it with other people.
TLS keys are removed after loading the process-local identity. OAuth credentials
stay in memory. The private local MCP PNG is ephemeral: it is refreshed while
unpaired, removed on pairing/quit, and rejected by local tools after five seconds
without a heartbeat. A crash may leave a stale image file, which is not accepted.

Native game/Steam/Proton behavior and sleep/resume still need player acceptance;
CI's native gates observe virtual-device state through XInput and evdev.

## Windows driver

The adapter uses [vgamepad](https://github.com/yannbouteiller/vgamepad) and requires
the [ViGEmBus driver](https://github.com/nefarius/ViGEmBus/releases). Install the
driver yourself and reboot if its installer requests it before starting Thumble.
The receiver never installs a driver or elevates itself. ViGEmBus is archived;
this is a compatibility backend for the preview, not a commitment to that driver
for production distribution. A missing driver is a startup error, never a silent
switch to simulated output. Python dependencies and the client DLL are bundled
in the executable; the kernel driver is not.

The Python dependency is pinned to upstream commit
`3f910aa8bbde49a576683db74ad5e4a0879f8a80`, which supports
`VGAMEPAD_SKIP_VIGEMBUS_INSTALL=true`. The older PyPI 0.1.0 release ignores that
setting and can launch an interactive installer during package installation.
The Windows freeze hook includes client DLLs and metadata without importing
vgamepad (which connects to the bus at import time) or bundling its driver MSIs.

## Linux permissions

The adapter uses [python-evdev UInput](https://python-evdev.readthedocs.io/en/latest/tutorial.html#specifying-uinput-device-options).
Load `uinput` and grant your logged-in user access to `/dev/uinput`. On a desktop
using systemd-logind, an administrator can install a narrowly scoped rule:

```sh
sudo modprobe uinput
echo 'KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput"' | sudo tee /etc/udev/rules.d/70-thumble-uinput.rules
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=misc --sysname-match=uinput
```

Log out and back in if permissions do not update. Distribution-specific udev and
session policies may require administrator configuration. Run the receiver as
your normal user, not root. Do not make `/dev/uinput` world-writable. Headless
systems need an administrator-managed access policy instead of a logind seat.
Rumble/force feedback is not implemented.

## Develop from source

Requires Python 3.11+ (CI uses 3.12). From the repository root:

```powershell
# Windows: prevent vgamepad's pip installer from launching a driver installer.
$env:VGAMEPAD_SKIP_VIGEMBUS_INSTALL = 'true'
py -3.12 -m venv .venv-desktop
.\.venv-desktop\Scripts\python -m pip install ./apps/receiver-desktop
.\.venv-desktop\Scripts\thumble-receiver --address 192.168.1.20
```

```sh
# Linux (building evdev may require your distro's Python headers/compiler).
python3 -m venv .venv-desktop
.venv-desktop/bin/python -m pip install ./apps/receiver-desktop
.venv-desktop/bin/thumble-receiver --address 192.168.1.20
```

`--dry-run` pairs normally and exercises access/protocol handling with memory-only
output, including on a Mac. It still uses the demo ledger, so use a separate
`--data-dir` for QA. `--self-test` runs entirely on loopback with a temporary
ledger and no native driver, network-interface selection, or printed invitation:

```sh
thumble-receiver --self-test
python -m unittest discover -s apps/receiver-desktop/tests -v
```

User data defaults to `%LOCALAPPDATA%\Thumble` on Windows and
`${XDG_STATE_HOME:-~/.local/state}/thumble` on Linux. `demo.json` holds the receiver
ID and prepaid demo ledger; `pro-grant.json` holds the signed purchase grant.
Invalid/unwritable ledgers exhaust the demo rather than reset its timer. One
process can own a data directory at a time. Files are replaced atomically and
flushed before time is granted. OS account permissions protect this state;
local administrator tampering is outside the ledger's trust boundary.

## Profiles and local agent tools

The phone's profile menu lists the Xbox and ConsolePort starters plus saved local
profiles. Selecting or explicitly adopting a cloud revision copies validated data
into the local store, releases controls, waits for the phone to render, and then
requires a fresh neutral acknowledgement. Gameplay stays paused until Resume.
Lost-response cloud-adoption retries reuse the same immutable copy and activation.
An expired lease or stale activation revision cannot overwrite a newer selection.

The profile directory defaults to `profiles` inside the data directory above.
The local Node MCP server (`node packages/profile-tools/src/server.js`) now uses
the matching Windows/Linux defaults, and keeps the existing Mac directory.
Use `--profile-dir` or `TAPPING_PROFILE_DIR` when sharing an alternate store with
local agent tools. Set the same override in the agent process. The receiver polls
external activations, so agent writes use the same render/neutral handshake.
`receiver-status.json` is ready only after current-layout neutral recovery; local
tools treat status older than five seconds as unavailable. A directory
`write.lock` serializes transactions with the existing agent tools. Never remove
that lock while a writer is running; a crashed writer's lock requires manual
recovery after confirming that no process owns it.

Profile selection, validation, saved-file reads, ConsolePort polling, and store
writes run on a separate worker. They never hold the networking loop while
waiting for a file lock. Only an authenticated `profile-adopt` may exceed the
normal 4 KiB request limit (up to 64 KiB); profiles themselves are limited to
60,000 bytes and stores to 8 MiB / 256 entries. Profiles cannot contain scripts,
URLs for artwork, keyboard actions, or arbitrary output types.

## ConsolePort sync

Install the ThumbleBridge addon in WoW and enable sync with `/thumblebridge sync on`.
Start the receiver with the WoW installation root or an individual client folder:

```powershell
.\thumble-receiver.exe --address 192.168.1.20 --wow-dir 'C:\Program Files (x86)\World of Warcraft'
```

```sh
./thumble-receiver --address 192.168.1.20 --wow-dir '/path/to/World of Warcraft/_classic_era_'
```

For Linux/Wine, point to the game folder inside the selected Wine prefix. The
receiver does not guess Wine/Steam installation paths. `--wow-dir` may be repeated
for up to eight roots; omitting it disables filesystem sync. With no active
profile, sync uses the ConsolePort starter; otherwise select a ConsolePort-themed
profile on the phone before reloading WoW.

The first scan records a baseline and does not activate an old logged-out
character. After a new `/reload` or logout saves
`WTF/Account/.../SavedVariables/ThumbleBridge.lua`, the receiver reads only the
`syncText` Lua string and validates its JSON snapshot. No Lua is evaluated and no
game files are written. Snapshots must be within five minutes of the computer's
clock. Invalid/stale exports, changed files, and non-ConsolePort active profiles
retain the previous controller. Symlink escapes and directory traversal are
bounded and rejected. Disable addon export with `/thumblebridge sync off`, then
reload; the existing controller stays in place.

Labels, all modifier layers, modifier assignments, and utility icons sync.
Attack has embedded fallback artwork. Other spell/item icon names are looked up
from the same fixed Wowhead tooltip endpoint as the Mac receiver, with a two-second
budget, at most six requests per sync, and a bounded cache. Lookup failures keep
labels usable; no profile can supply a URL. Geometry
and gamepad mappings are retained from the selected ConsolePort layout. Phone
summaries expose the character name and sync state, not account paths or GUIDs.

## CI and validation limits

`.github/workflows/desktop-receiver.yml` runs a complete batch on Windows and
Ubuntu: native dependency installation (without driver installation), protocol
and adapter unit tests, ConsolePort/profile fixtures, real phone connection
integration over loopback TLS, shared Node controller/agent-tool tests, installed
CLI smoke test, PyInstaller build, frozen executable TLS/input/profile-adoption
smoke test, then artifact upload. Test failures prevent artifact publication.
The existing POSIX permission fixtures run on Linux; a cross-runtime test verifies
the protected Windows QR file through the actual Node MCP reader. PR updates run one Windows/Linux matrix, avoiding
duplicate push/PR builds of the same branch batch.

Adapter tests check Windows API calls and Linux event capabilities, axis signs,
button masks, hats, neutral release, and cleanup. Native CI gates separately install
the checksum/signature-verified Windows driver on the ephemeral runner, load Linux
uinput, and use `--native-self-test` to observe real XInput/evdev state from
authenticated TLS input and watchdog release. Native chat QA types into isolated
test widgets, never a game or human chat. Package checks install/uninstall the app,
run the installed protocol test, exercise the registered custom URI handler, and
capture a synthetic GUI screenshot. These gates must pass before artifacts upload.
`--self-test` prints no pairing secret and uses memory output; `--native-self-test`
intentionally emits a short known gamepad report and requires the driver.

## ChatGPT pairing and chat

Choose **Pair through ChatGPT…**, sign in to the same Thumble account as the
ChatGPT connector, and allow `pairing:manage`. The installed custom URI handler
forwards the callback to the existing receiver's loopback broker. PKCE, exact
issuer/redirect checks, and one-use state protect authorization. No refresh token
is saved. Sharing lasts ten minutes, heartbeats every ten seconds, clears the QR
when paired, and revokes on Stop/quit; hosted freshness expires within 30 seconds
if a final revoke cannot reach the service.

Ask the local or hosted MCP tool for `show_pairing_code` to display the native PNG.
Gameplay remains LAN-only. The private local reader enforces owner-only POSIX
permissions or an explicit Windows ACL permitting only the current SID and SYSTEM.

Phone chat supports Say, Party, Raid, Guild, and Instance. Bring WoW to the front
first. Only literal single-line text up to 240 UTF-8 bytes is accepted; the receiver
adds the channel prefix. Controls release while typing, focus/cancellation is
checked throughout, and request IDs prevent duplicate delivery. Windows messages
target the captured WoW window instead of global SendInput. Linux requires
`xdotool` and a usable X11/XWayland display; pure Wayland cannot provide this
targeted API. Delivery confirms OS submission, not a game-server receipt.

Enable lower-latency input with `--transport udp`. The fresh key travels only over
pinned TLS. Directional counters, AES-GCM authentication, anti-replay checks, and
an authenticated probe bind one UDP endpoint per phone. Profile, access, and chat
messages stay on TLS. If the encrypted probe cannot complete, the phone keeps WSS.

Production follow-up should evaluate a maintained Windows virtual controller
driver, finish real-game/sleep acceptance, and configure production signing/update
credentials before treating these preview artifacts as a public production release.
