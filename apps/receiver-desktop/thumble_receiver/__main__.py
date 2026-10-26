import argparse
import asyncio
import os
from pathlib import Path
import signal
import sys

import qrcode

from .access import Access
from .lock import DirectoryLock
from .output import GuardedOutput, MemoryOutput, native_output
from .pairing import Invitation, detect_address, identity, private_ipv4
from .server import ReceiverServer
from .profiles import ProfileStore


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


async def run(args):
    address = private_ipv4(args.address) if args.address else detect_address()
    context, fingerprint = identity()
    # No fallback: missing drivers/permissions are a startup failure.
    output = GuardedOutput(MemoryOutput() if args.dry_run else native_output())
    lock = None
    try:
        lock = DirectoryLock(args.data_dir)
        access = Access(args.data_dir)
        profile_dir = args.profile_dir or Path(args.data_dir) / 'profiles'
        server = ReceiverServer(output, access, Invitation(address, args.port, fingerprint), display_invitation,
                                profiles=ProfileStore(profile_dir), wow_roots=args.wow_dir)
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        previous = {}
        for kind in (signal.SIGINT, signal.SIGTERM):
            previous[kind] = signal.signal(kind, lambda *_: loop.call_soon_threadsafe(stop.set))
        print('Thumble desktop preview' + (' · DRY RUN: no gamepad output' if args.dry_run else ''), flush=True)
        print(f'Listening on {address}; Ctrl+C releases controls and exits.', flush=True)
        try:
            # Bind the selected LAN interface rather than every interface.
            await server.run(address, args.port, context, stop)
        finally:
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
    parser = argparse.ArgumentParser(description='Thumble Windows/Linux receiver preview')
    parser.add_argument('--address', help='Private IPv4 address of this computer on the phone Wi-Fi')
    parser.add_argument('--port', type=int, default=0, help='WSS port (default: an available port)')
    parser.add_argument('--data-dir', type=Path, default=data_directory())
    parser.add_argument('--profile-dir', type=Path, default=os.environ.get('TAPPING_PROFILE_DIR'),
                        help='Local-agent profile store (default: data directory / profiles)')
    parser.add_argument('--wow-dir', type=Path, action='append', default=[],
                        help='WoW install/client folder for saved ConsolePort sync; may be repeated')
    parser.add_argument('--dry-run', action='store_true', help='Pair normally but emit no native gamepad input')
    parser.add_argument('--self-test', action='store_true', help='Check TLS and input protocol on loopback with no native output')
    args = parser.parse_args()
    if not 0 <= args.port <= 65535:
        parser.error('port must be between 0 and 65535')
    if len(args.wow_dir) > 8:
        parser.error('at most eight WoW roots are supported')
    try:
        if args.self_test:
            from .selftest import selftest
            asyncio.run(selftest())
        else:
            asyncio.run(run(args))
    except (OSError, ValueError, RuntimeError, ImportError) as error:
        parser.exit(1, f'Receiver could not start: {error}\nSee apps/receiver-desktop/README.md for driver setup.\n')


if __name__ == '__main__':
    main()
