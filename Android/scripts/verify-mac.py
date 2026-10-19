#!/usr/bin/env python3
"""Run the optional Pixel/Mac interop test using a live Mac CLI pairing payload.
No credential files are written; no pairing payload is printed. Pairing only by default.
"""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser()
source = parser.add_mutually_exclusive_group(required=True)
source.add_argument('--cli', type=Path, help='Packaged thumble CLI with sibling bridges')
source.add_argument('--native-domain', help='Isolated native helper defaults domain')
parser.add_argument('--native-home', type=Path, help='CFFIXED_USER_HOME of the isolated native helper')
parser.add_argument('--verify-reconnect', action='store_true', help='Verify real service-only QR, encrypted trust reload, and changed-address discovery')
parser.add_argument('--render-ui', action='store_true', help='Verify and capture the visible controller UI instead of exercising input')
parser.add_argument('--exercise-input', action='store_true', help='Send two test holds, only to a receiver with input disabled')
parser.add_argument('--keyboard-probe-log', type=Path, help='Explicit real-input test: JSONL from the focused keyboard-probe.swift responder')
parser.add_argument('--expected-keycodes', help='Two macOS key codes expected in the probe, in control order')
parser.add_argument('--control-ids', help='Two keyboard control UUIDs to touch in the visible app')
parser.add_argument('--require-udp', action='store_true', help='Require real UDP input execution')
parser.add_argument('--require-fallback', action='store_true', help='Require reliable fallback input execution during UDP loss')
parser.add_argument('--serial', required=True)
parser.add_argument('--adb', default=os.environ.get('ADB', 'adb'))
parser.add_argument('--url', help='Override reachable ws:// address (e.g. emulator 10.0.2.2)')
args = parser.parse_args()
if args.verify_reconnect and (not args.cli or args.render_ui or args.exercise_input):
    parser.error('--verify-reconnect requires --cli and cannot be combined with UI/input exercise flags')

def status():
    if args.native_domain:
        env = dict(os.environ)
        if args.native_home:
            env['CFFIXED_USER_HOME'] = str(args.native_home.resolve())
        result = subprocess.run(['swift', str(Path(__file__).with_name('native-status.swift')), args.native_domain],
            env=env, capture_output=True, check=True)
        return json.loads(result.stdout)
    result = subprocess.run([str(args.cli.resolve()), 'status', '--json'], capture_output=True, text=True, check=True)
    envelope = json.loads(result.stdout)
    return envelope.get('response', {}).get('status', envelope)

root = Path(__file__).resolve().parents[1]
for apk in [root / 'app/build/outputs/apk/debug/app-debug.apk', root / 'app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk']:
    if not apk.exists():
        raise SystemExit('Build assembleDebug assembleDebugAndroidTest first.')
    subprocess.run([args.adb, '-s', args.serial, 'install', '-r', str(apk)], check=True, capture_output=True)
before = status()
if before.get('core', {}).get('paired') or before.get('isClientConnected'):
    raise SystemExit('A phone is already paired. Disconnect it before this test.')
urls = before.get('urls', before.get('localURLs', []))
if args.url:
    urls = [args.url]
else:
    from urllib.parse import urlsplit
    def lan(url):
        try:
            ip = ipaddress.ip_address(urlsplit(url).hostname)
            return ip.is_private and not ip.is_loopback and not ip.is_link_local
        except ValueError:
            return False
    urls = sorted(urls, key=lambda url: not lan(url))
if not urls or not before.get('pairingCode'):
    raise SystemExit('Mac status did not provide a pairing code and reachable address.')
if args.keyboard_probe_log:
    if not (args.exercise_input and args.render_ui and args.control_ids and len(args.control_ids.split(',')) == 2 and args.expected_keycodes and len(args.expected_keycodes.split(',')) == 2):
        raise SystemExit('Real keyboard testing requires --render-ui --exercise-input and two --control-ids.')
    if not (before.get('inputEnabled') is True and before.get('accessibilityTrusted') is True):
        raise SystemExit('Real input and macOS Accessibility must both be enabled.')
    records = [json.loads(line) for line in args.keyboard_probe_log.read_text().splitlines()]
    if time.time() - args.keyboard_probe_log.stat().st_mtime > 1 or not records or records[-1] != {'kind': 'focus', 'focused': True}:
        raise SystemExit('Keyboard probe must be running and focused immediately before the test.')
if args.exercise_input and not args.keyboard_probe_log and not (before.get('inputEnabled') is False or before.get('accessibilityTrusted') is False):
    raise SystemExit('Input exercise requires a recording/no-input receiver or an isolated helper without Accessibility permission.')
capture = Path(before['captureLogPath']) if args.native_domain and before.get('captureLogPath') else None
capture_offset = capture.stat().st_size if capture and capture.exists() else 0
qr = json.dumps({'type': 'pocketpad-pair', 'urls': urls, 'pairingCode': before['pairingCode'], 'serverID': before.get('serverID')})
result = subprocess.run([args.adb, '-s', args.serial, 'shell', 'am', 'instrument', '-w', '-r',
    '-e', 'class', ('com.thumble.android.SessionRecoveryTest#optionalMacSavedTrustAndNearbyDiscovery' if args.verify_reconnect else 'com.thumble.android.VerticalSliceTest#' + ('optionalMacControllerUIScreen' if args.render_ui else 'optionalMacHostPairingWithRealProfile')),
    '-e', 'macExerciseInput', str(args.exercise_input).lower(),
    *(['-e', 'macControlIDs', args.control_ids] if args.control_ids else []),
    '-e', 'macRequireUDP', str(bool(args.native_domain) or args.require_udp).lower(),
    '-e', 'macPairingQR', "'" + qr.replace("'", "'\\''") + "'",
    'com.thumble.android.test/androidx.test.runner.AndroidJUnitRunner'], capture_output=True, text=True)
print(result.stdout)
if result.returncode != 0 or 'FAILURES' in result.stdout or 'OK (1 test)' not in result.stdout:
    raise SystemExit('Live Mac interoperability test failed.')
after = status()
# ActivityScenario.finish schedules lifecycle teardown; wait for the socket close to reach the host.
deadline = time.monotonic() + 5
while (after.get('isClientConnected') or after.get('core', {}).get('paired')) and time.monotonic() < deadline:
    time.sleep(0.1)
    after = status()
if after.get('pressedButtons') or after.get('pressedElementInputs') or after.get('core', {}).get('pressedButtons') or after.get('core', {}).get('pressedElements'):
    raise SystemExit('Receiver still reports held inputs after test.')
if after.get('isClientConnected') or after.get('core', {}).get('paired'):
    raise SystemExit('Receiver still reports a paired client after disconnect.')
if not args.native_domain and args.exercise_input:
    accepted = after.get('core', {}).get('counters', {}).get('acceptedInputs', 0) - before.get('core', {}).get('counters', {}).get('acceptedInputs', 0)
    if accepted < 6:
        raise SystemExit(f'Receiver accepted only {accepted} input edges; expected at least six.')
    if after.get('output', {}).get('heldKeyCount') or after.get('output', {}).get('heldPointerButtons'):
        raise SystemExit('Receiver output still has held keys or pointer buttons.')
    print(f'Rust receiver accepted {accepted} input edges.')
    if args.require_udp:
        udp = after.get('realtime', {}).get('udpAcceptedInputs', 0) - before.get('realtime', {}).get('udpAcceptedInputs', 0)
        ws = after.get('realtime', {}).get('websocketAcceptedInputs', 0) - before.get('realtime', {}).get('websocketAcceptedInputs', 0)
        if udp < 2 or (args.require_fallback and ws < 4):
            raise SystemExit(f'Expected two UDP downs and at least four reliable fallback edges; received UDP={udp}, WS={ws}.')
        executed = after['output']['eventsExecuted'] - before['output']['eventsExecuted']
        if executed != 6:
            raise SystemExit(f'Expected exactly six executed keyboard events after deduplication, got {executed}.')
        counters = {field: after['core']['counters'][field] - before['core']['counters'][field]
            for field in ['expiredHolds', 'rejectedInputs', 'staleGenerations', 'duplicateSequences']}
        if counters['expiredHolds']:
            raise SystemExit('Receiver expired a hold during real input test.')
        # A faster UDP release barrier may overtake an older mirrored heartbeat/input.
        # Retiring that generation is expected; other rejection reasons still fail.
        if counters['rejectedInputs'] != counters['staleGenerations']:
            raise SystemExit(f'Receiver reported unexpected input rejections: {counters}')
        print(f'Rust executed {udp} UDP inputs and {ws} WebSocket inputs; exactly six keyboard events.')
        (root / 'app/build/evidence/udp-input-result.json').write_text(json.dumps({
            'udpAcceptedInputs': udp, 'websocketAcceptedInputs': ws, 'keyboardEvents': executed,
            'heldKeyCount': after['output']['heldKeyCount'], **counters}, indent=2) + '\n')
if args.native_domain and args.exercise_input and not args.render_ui and capture:
    with capture.open('rb') as log:
        log.seek(capture_offset)
        events = [json.loads(line) for line in log if line.strip()]
    udp_buttons = [event for event in events if event.get('kind') == 'button' and event.get('source') == 'iPhone UDP']
    fallback_buttons = [event for event in events if event.get('kind') == 'button' and event.get('source') == 'iPhone']
    if not (any(len(event.get('pressedButtons', [])) >= 2 for event in udp_buttons)
            and sum(event.get('state') == 'up' for event in udp_buttons) >= 2
            and any(event.get('state') == 'down' for event in fallback_buttons)
            and any(event.get('state') == 'up' for event in fallback_buttons)):
        raise SystemExit('Native capture did not confirm concurrent UDP holds, both releases, and WebSocket fallback down/up.')
    print(f'Native receiver confirmed {len(udp_buttons)} UDP edges and {len(fallback_buttons)} WebSocket fallback edges.')
if args.render_ui:
    evidence = root / 'app/build/evidence/vertical-slice-controller.png'
    evidence.parent.mkdir(parents=True, exist_ok=True)
    with evidence.open('wb') as output:
        subprocess.run([args.adb, '-s', args.serial, 'exec-out', 'run-as', 'com.thumble.android', 'cat', 'cache/vertical-slice-controller.png'], stdout=output, check=True)
    print(f'Controller screenshot: {evidence}')
if args.keyboard_probe_log:
    records = [json.loads(line) for line in args.keyboard_probe_log.read_text().splitlines()]
    expected = [int(code) for code in args.expected_keycodes.split(',')]
    edges = [row for row in records if row.get('kind') in ('down', 'up') and not row.get('repeat')]
    sequence = [(row['kind'], row['keyCode']) for row in edges]
    if sequence != [('down', expected[0]), ('down', expected[1]), ('up', expected[1]), ('up', expected[0]), ('down', expected[0]), ('up', expected[0])]:
        raise SystemExit(f'Mac key sequence did not match the requested controls: {sequence}')
    first = next(i for i, row in enumerate(records) if row.get('kind') == 'down')
    last = max(i for i, row in enumerate(records) if row.get('kind') == 'up')
    if any(row.get('kind') == 'focus' and not row.get('focused') for row in records[first:last + 1]):
        raise SystemExit('Mac keyboard probe lost focus during input.')
    downs = [row for row in records if row.get('kind') == 'down' and not row.get('repeat')]
    ups = [row for row in records if row.get('kind') == 'up']
    if len(downs) < 3 or len(ups) < 3 or not any(len(row.get('held', [])) >= 2 for row in downs) or ups[-1].get('held'):
        raise SystemExit('Focused Mac responder did not observe overlapping holds and complete releases.')
    print('Mac AppKit responder received keyboard downs:', [(row['keyCode'], row['characters']) for row in downs])
    print('Mac AppKit responder confirmed both releases and touch-cancel release; no keys remain held.')
if args.verify_reconnect:
    evidence = root / 'app/build/evidence/session-recovery-result.json'
    evidence.parent.mkdir(parents=True, exist_ok=True)
    with evidence.open('wb') as output:
        subprocess.run([args.adb, '-s', args.serial, 'exec-out', 'run-as', 'com.thumble.android', 'cat', 'cache/session-recovery-result.json'], stdout=output, check=True)
    print('Real Bonjour service-only pairing, encrypted trust reload, and changed-address discovery passed.')
print('Live Mac pairing and real-profile decoding passed; receiver has no held inputs.')
