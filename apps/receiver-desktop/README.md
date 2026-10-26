# Thumble desktop receiver preview

Windows 10/11 x64 and Linux x64 receiver for the existing Thumble phone app. This
is a separate Python implementation of the Mac receiver's v3 LAN protocol. The
signed Swift macOS app continues to live in `apps/receiver`.

Implemented in this first port:

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

The preview uses the phone's built-in controller at layout revision zero. Custom
profile catalogs/adoption, ConsolePort settings sync, chat delivery, UDP input,
hosted ChatGPT pairing, tray UI, auto-start, installers, signing, and automatic
updates are follow-up work. Unsupported capabilities are not advertised to the
phone. Existing phone copy still calls the computer “Mac”; **Connect Mac** also
scans this receiver's invitation. No mobile changes are needed for basic input.

## Run a CI artifact

Download the artifact for your OS from the **Desktop receiver** GitHub Actions
run. Extract the executable, complete driver setup below, and run it in a terminal:

```powershell
# Windows PowerShell
.\thumble-receiver.exe --address 192.168.1.20 --port 8765
```

```sh
# Linux: restore executable permission after extracting the ZIP.
chmod +x ./thumble-receiver
./thumble-receiver --address 192.168.1.20 --port 8765
```

Use this computer's Wi-Fi IPv4 address. With no `--address`, the receiver selects
the default route's private IPv4 interface; specify it explicitly if a VPN or
multiple adapters select the wrong network. The phone must be on the same LAN.
Allow inbound TCP for the chosen port on the private network in the OS firewall.
No router port forwarding is needed. Omitting `--port` chooses an available port.

Scan the QR in Thumble's **Connect Mac** screen, then use **Start demo / Resume**.
The QR renews after expiry or disconnect. Ctrl+C releases the pad and exits.
Keep the QR private; do not capture it in CI logs or share it with other people.
No credentials, TLS keys, or invitations are retained in the data directory.

These are unsigned preview executables. Native game/Steam/Proton recognition and
sleep/resume behavior still require verification on real target machines.

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

## CI and validation limits

`.github/workflows/desktop-receiver.yml` runs a complete batch on Windows and
Ubuntu: native dependency installation (without driver installation), protocol
and adapter unit tests, real loopback TLS integration tests, installed CLI smoke
test, PyInstaller executable build, frozen executable TLS/input/watchdog smoke
test, then artifact upload. Test failures prevent artifact publication.

Adapter tests check Windows API calls and Linux event capabilities, axis signs,
button masks, hats, neutral release, and device cleanup with driver doubles.
Hosted CI does **not** prove that a kernel driver is installed, a virtual pad is
enumerated, or a game accepts it. That final acceptance requires a Windows/Linux
machine with its driver configured. The self-test prints no pairing secret and
does not install drivers or emit OS input.

Production follow-up should evaluate a maintained Windows virtual controller
driver, add native device/game acceptance coverage, port profile/ConsolePort
features, and add signed installation/update paths before calling this release
parity with the Mac app.
