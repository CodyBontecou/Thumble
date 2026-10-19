#!/usr/bin/env python3
"""Verify Android profile actions against a private Rust receiver, preserving the normal Mac.

Pairing credentials stay in subprocess memory; saved evidence contains no tokens.
"""
import argparse
import copy
import ipaddress
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from urllib.parse import urlsplit

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--host', type=Path, required=True)
parser.add_argument('--serial', required=True)
parser.add_argument('--adb', default='adb')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
host = str(args.host.resolve())
fixture = json.loads((root.parent / 'Host/fixtures/controller-templates/v1/productivityStarter.json').read_text())['profile']
first = copy.deepcopy(fixture)
first['orientationPreference'] = 'automatic'
second = copy.deepcopy(first)
second.update(id='77aa418b-aa10-4bb0-8220-6c23fed80200', name='Android profile action acceptance')
initial = dict(schemaVersion=3, serverID='android-profile-actions', trustedClients={},
               profiles=[first, second], activeProfileID=first['id'], defaultProfileID=first['id'])
with tempfile.TemporaryDirectory(prefix='thumble-profile-actions-') as directory:
    path = Path(directory)
    state_file = path / 'state.json'
    state_file.write_text(json.dumps(initial))
    state_file.chmod(0o600)
    env = dict(os.environ, THUMBLE_HOST_STATE_DIR=directory,
               THUMBLE_HOST_CONTROL_SOCKET=str(path / 'control.sock'))
    def run(*command):
        value = subprocess.run([host, *command], env=env, capture_output=True, text=True)
        if value.returncode:
            raise RuntimeError('Private Rust receiver command failed')
        return value.stdout
    def status():
        value = json.loads(run('status', '--json'))
        return value.get('status', value.get('response', {}).get('status', value))
    started = False
    try:
        run('start', '--port', '0', '--no-input', '--no-bonjour')
        started = True
        before = status()
        assert before['inputEnabled'] is False
        original = json.loads(state_file.read_text())
        if args.serial.startswith('emulator-'):
            urls = [f"ws://10.0.2.2:{before['port']}"]
        else:
            def lan(url):
                address = ipaddress.ip_address(urlsplit(url).hostname)
                return address.version == 4 and address.is_private and not address.is_loopback and not address.is_link_local
            urls = [url for url in before['urls'] if lan(url)]
        assert urls, 'No receiver endpoint reachable from Android'
        qr = json.dumps(dict(type='pocketpad-pair', urls=urls,
                             pairingCode=before['pairingCode'], serverID=before['serverID']))
        base = [args.adb, '-s', args.serial]
        for apk in ['app/build/outputs/apk/debug/app-debug.apk', 'app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk']:
            subprocess.run(base + ['install', '-r', str(root / apk)], capture_output=True, check=True)
        result = subprocess.run(base + ['shell', 'am', 'instrument', '-w', '-r',
            '-e', 'class', 'com.thumble.android.ProfileActionsDeviceTest#optionalRustProfileActionsInterop',
            '-e', 'profileActionsPairingQR', "'" + qr.replace("'", "'\\''") + "'",
            'com.thumble.android.test/androidx.test.runner.AndroidJUnitRunner'], capture_output=True, text=True)
        # Assertion messages deliberately omit the pairing payload and host state.
        if result.returncode or 'OK (1 test)' not in result.stdout or 'FAILURES' in result.stdout:
            print(result.stdout)
            raise RuntimeError('Android/Rust profile-action interoperability failed')
        after = status()
        deadline = time.monotonic() + 5
        while after['core']['paired'] and time.monotonic() < deadline:
            time.sleep(.1)
            after = status()
        saved = json.loads(state_file.read_text())
        expected = copy.deepcopy(original['profiles'])
        expected[0]['orientationPreference'] = 'automatic'
        assert saved['profiles'][0]['updatedAt'] > 0
        expected[0]['updatedAt'] = saved['profiles'][0]['updatedAt']
        assert saved['profiles'] == expected, 'Profile content changed beyond orientation metadata'
        assert saved['activeProfileID'].lower() == first['id'].lower()
        assert saved['defaultProfileID'].lower() == second['id'].lower()
        assert saved['configurationRevision'] == before['core']['configurationRevision'] + 4
        assert not after['core']['paired']
        assert not after['output']['heldKeyCount'] and not after['output']['heldPointerButtons']
        receipt = dict(androidRustProfileActions='passed', orientationPreferences=['portrait', 'landscape', 'automatic'],
                       configurationRevisionDelta=4, activeProfileUnchanged=True, defaultProfileChanged=True,
                       layoutsAndBindingsUnchanged=True, receiverInputEnabled=False, paired=False,
                       heldKeyCount=0, heldPointerButtons=[], normalReceiverTouched=False)
        evidence = root / 'app/build/evidence/profile-actions'
        evidence.mkdir(parents=True, exist_ok=True)
        (evidence / 'rust-profile-actions-result.json').write_text(json.dumps(receipt, indent=2) + '\n')
        print(json.dumps(receipt, indent=2))
    finally:
        if started:
            run('stop')
