#!/usr/bin/env python3
"""Explicit, focused real-keyboard test. Requires an input-enabled, trusted Mac host.
Control IDs and expected codes must refer to two plain keyboard buttons in the active profile.
"""
import argparse
import json
import importlib.util
import ipaddress
from urllib.parse import urlsplit
from pathlib import Path
import subprocess
import tempfile
import shutil
import time

parser = argparse.ArgumentParser()
parser.add_argument('--cli', required=True, type=Path)
parser.add_argument('--serial', required=True)
parser.add_argument('--adb', default='adb')
parser.add_argument('--require-udp', action='store_true', help='Require real UDP execution on the direct connection')
parser.add_argument('--drop-udp', action='store_true', help='Relay real traffic and drop UDP after two distinct downs')
parser.add_argument('--control-ids', required=True)
parser.add_argument('--expected-keycodes', required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
evidence = root / 'app/build/evidence/mac-keyboard-events.jsonl'
evidence.parent.mkdir(parents=True, exist_ok=True)
def status():
    value = json.loads(subprocess.run([str(args.cli.resolve()), 'status', '--json'], capture_output=True, text=True, check=True).stdout)
    return value.get('response', {}).get('status', value)

relay = None
relay_args = ['--require-udp'] if args.require_udp else []
if args.drop_udp:
    initial = status()
    if not initial.get('realtime', {}).get('enabled'):
        raise SystemExit('The Rust receiver must advertise realtime UDP before testing loss.')
    address = next((urlsplit(url).hostname for url in initial['urls']
        if ipaddress.ip_address(urlsplit(url).hostname).version == 4
        and ipaddress.ip_address(urlsplit(url).hostname).is_private
        and not ipaddress.ip_address(urlsplit(url).hostname).is_loopback
        and not ipaddress.ip_address(urlsplit(url).hostname).is_link_local), None)
    if not address:
        raise SystemExit('No LAN IPv4 address available for the fault relay.')
    spec = importlib.util.spec_from_file_location('udp_drop_relay', Path(__file__).with_name('udp-drop-relay.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    relay = module.UDPDropRelay(initial['port'])
    relay_args = ['--url', f'ws://{address}:{relay.port}', '--require-udp', '--require-fallback']
with tempfile.TemporaryDirectory(prefix='thumble-keyboard-') as temporary:
    binary = Path(temporary) / 'keyboard-probe'
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(Path(temporary) / 'modules'),
        str(Path(__file__).with_name('keyboard-probe.swift')), '-o', str(binary)], check=True)
    evidence.unlink(missing_ok=True)
    probe = subprocess.Popen([str(binary), str(evidence)])
    try:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if probe.poll() is not None:
                raise SystemExit('Mac keyboard probe exited before acquiring focus.')
            if evidence.exists() and evidence.stat().st_size:
                records = evidence.read_text().splitlines()
                if records and json.loads(records[-1]).get('focused'):
                    break
            time.sleep(0.1)
        else:
            raise SystemExit('Mac keyboard probe did not acquire focus.')
        result = subprocess.run(['python3', str(Path(__file__).with_name('verify-mac.py')),
            '--cli', str(args.cli.resolve()), '--serial', args.serial, '--adb', args.adb,
            '--render-ui', '--exercise-input', '--keyboard-probe-log', str(evidence),
            '--control-ids', args.control_ids, '--expected-keycodes', args.expected_keycodes] + relay_args)
    finally:
        # Emergency release is sent even if the Android test or evidence assertion fails.
        subprocess.run([str(args.cli.resolve()), 'release-all'], capture_output=True)
        probe.terminate()
        probe.wait(timeout=5)
        if relay:
            relay.close()
    if relay:
        summary = relay.summary()
        (evidence.parent / 'udp-drop-relay.json').write_text(json.dumps(summary, indent=2) + '\n')
        print('UDP drop relay:', summary)
        if summary['distinctForwardedDowns'] != 2 or summary['droppedButtonUps'] < 3 or summary['droppedDatagrams'] < 4:
            raise SystemExit('Relay did not prove UDP loss across holds and releases.')
        if result.returncode == 0:
            saved = evidence.parent / 'udp-drop'
            saved.mkdir(exist_ok=True)
            for name in ['mac-keyboard-events.jsonl', 'vertical-slice-controller.png', 'udp-input-result.json', 'udp-drop-relay.json']:
                shutil.copy2(evidence.parent / name, saved / name)
    raise SystemExit(result.returncode)
