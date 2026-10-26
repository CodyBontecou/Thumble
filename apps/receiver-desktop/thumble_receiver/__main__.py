import argparse
import asyncio
import os
from pathlib import Path
import signal
import sys
import threading
import contextlib

import qrcode

from .access import Access
from .lock import DirectoryLock
from .output import GuardedOutput, MemoryOutput, native_output
from .pairing import Invitation, detect_address, identity, private_ipv4
from .server import ReceiverServer
from .profiles import ProfileStore
from .chat import native_chat
from .cloud_pairing import CallbackBroker, CloudPairing, forward_callback


def data_directory():
    if sys.platform == 'win32':
        return Path(os.environ.get('LOCALAPPDATA', Path.home() / 'AppData/Local')) / 'Thumble'
    return Path(os.environ.get('XDG_STATE_HOME', Path.home() / '.local/state')) / 'thumble'


def display_invitation(link):
    print('\nScan in Thumble on the same Wi-Fi (expires in two minutes):', flush=True)
    qr = qrcode.QRCode(border=2)
    qr.add_data(link)
    qr.make(fit=True)
    qr.print_ascii(invert=True)
    print('Pairing credentials are private. Keep this terminal off shared logs.', flush=True)


async def run(args, ui=None):
    address = private_ipv4(args.address) if args.address else detect_address()
    context, fingerprint = identity()
    # No fallback: missing drivers/permissions are a startup failure.
    output = GuardedOutput(MemoryOutput() if args.dry_run else native_output())
    lock = None
    try:
        lock = DirectoryLock(args.data_dir)
        access = Access(args.data_dir)
        profile_dir = args.profile_dir or Path(args.data_dir) / 'profiles'
        cloud = None
        def invitation_changed(value):
            if ui:
                ui.events.invitation.emit(value)
            elif value:
                display_invitation(value)
            if cloud and cloud.token:
                asyncio.create_task(cloud.publish())
        server = ReceiverServer(output, access, Invitation(address, args.port, fingerprint), invitation_changed,
                                profiles=ProfileStore(profile_dir), wow_roots=[] if args.no_consoleport_sync else args.wow_dir,
                                enable_udp=args.transport == 'udp', chat=None if args.dry_run else native_chat())
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        broker = CallbackBroker(args.data_dir)
        await broker.start()
        cloud = CloudPairing(broker, lambda: server.current_invitation,
                             ui.events.cloud.emit if ui else print)
        if ui:
            server.on_status = ui.events.status.emit
            ui.attach(loop, server, stop, cloud)
        previous = {}
        if threading.current_thread() is threading.main_thread():
            for kind in (signal.SIGINT, signal.SIGTERM):
                previous[kind] = signal.signal(kind, lambda *_: loop.call_soon_threadsafe(stop.set))
        if not ui:
            print('Thumble desktop preview' + (' · DRY RUN: no gamepad output' if args.dry_run else ''), flush=True)
            print(f'Listening on {address}; Ctrl+C releases controls and exits.', flush=True)
        try:
            # Bind the selected LAN interface rather than every interface.
            await server.run(address, args.port, context, stop)
        finally:
            await cloud.stop()
            await broker.close()
            for kind, handler in previous.items():
                signal.signal(kind, handler)
            access.pause()
    finally:
        try:
            output.close()
        finally:
            if lock:
                lock.close()


def main():
    if os.name == 'nt' and sys.stdout is None and any(option in sys.argv for option in (
            '--headless', '--self-test', '--native-self-test', '--help', '--register-protocol')):
        import ctypes
        if ctypes.windll.kernel32.AttachConsole(0xffffffff):
            sys.stdout = open('CONOUT$', 'w', encoding='utf-8')
            sys.stderr = open('CONOUT$', 'w', encoding='utf-8')
    parser = argparse.ArgumentParser(description='Thumble Windows/Linux receiver preview')
    parser.add_argument('--address', help='Private IPv4 address of this computer on the phone Wi-Fi')
    parser.add_argument('--port', type=int, default=0, help='WSS port (default: an available port)')
    parser.add_argument('--data-dir', type=Path, default=data_directory())
    parser.add_argument('--profile-dir', type=Path, default=os.environ.get('TAPPING_PROFILE_DIR'),
                        help='Local-agent profile store (default: data directory / profiles)')
    parser.add_argument('--wow-dir', type=Path, action='append', default=[],
                        help='WoW install/client folder for saved ConsolePort sync; may be repeated')
    parser.add_argument('--transport', choices=('wss', 'udp'), default='wss',
                        help='Input transport (UDP uses AES-GCM with WSS control/fallback)')
    parser.add_argument('--headless', action='store_true', help='Use a terminal instead of the pairing window and tray')
    parser.add_argument('--no-consoleport-sync', action='store_true')
    parser.add_argument('--oauth-callback', help=argparse.SUPPRESS)
    parser.add_argument('--gui-smoke', type=Path, help=argparse.SUPPRESS)
    parser.add_argument('--native-self-test', action='store_true', help='Verify real virtual-gamepad state through the OS; requires the driver')
    parser.add_argument('--register-protocol', action='store_true', help='Register browser sign-in callbacks for this user')
    parser.add_argument('--install-user', action='store_true', help='Install the packaged Linux application for this user')
    parser.add_argument('--uninstall-user', action='store_true', help='Remove the installed Linux application and retain user data')
    parser.add_argument('--background', action='store_true', help='Start in the tray when a system tray is available')
    parser.add_argument('uri', nargs='?', help=argparse.SUPPRESS)
    parser.add_argument('--dry-run', action='store_true', help='Pair normally but emit no native gamepad input')
    parser.add_argument('--self-test', action='store_true', help='Check TLS and input protocol on loopback with no native output')
    args = parser.parse_args()
    if not 0 <= args.port <= 65535:
        parser.error('port must be between 0 and 65535')
    if len(args.wow_dir) > 8:
        parser.error('at most eight WoW roots are supported')
    try:
        # A protocol handler never performs another action, even if a malformed
        # custom URI caused additional recognized flags to appear in argv.
        if args.oauth_callback or args.uri:
            forward_callback(args.data_dir, args.oauth_callback or args.uri)
        elif args.self_test or args.native_self_test:
            from .selftest import selftest
            asyncio.run(selftest(native=args.native_self_test))
        elif args.install_user:
            from .install import install_user
            install_user()
        elif args.uninstall_user:
            from .install import uninstall_user
            uninstall_user()
        elif args.register_protocol:
            from .install import register_protocol
            register_protocol()
        elif args.gui_smoke:
            from .gui import smoke
            smoke(args, args.gui_smoke)
        elif not args.headless:
            from .gui import run_gui
            settings = {}
            with contextlib.suppress(OSError, ValueError, TypeError):
                import json
                settings = json.loads((args.data_dir / 'settings.json').read_bytes())
                if not isinstance(settings, dict):
                    settings = {}
            roots = settings.get('wowDirs', [])
            if not args.wow_dir and isinstance(roots, list) and len(roots) <= 8 and all(
                    isinstance(root, str) and 0 < len(root) <= 4096 for root in roots):
                args.wow_dir = [Path(root) for root in roots]
            if not args.address and isinstance(settings.get('address'), str):
                with contextlib.suppress(ValueError):
                    args.address = private_ipv4(settings['address'])
            if settings.get('syncEnabled') is False:
                args.no_consoleport_sync = True
            return run_gui(args, settings)
        else:
            asyncio.run(run(args))
    except (OSError, ValueError, RuntimeError, ImportError) as error:
        parser.exit(1, f'Receiver could not start: {error}\nSee apps/receiver-desktop/README.md for driver setup.\n')


if __name__ == '__main__':
    main()
