#!/usr/bin/env python3
"""Exercise native Android advanced gestures against a private Rust receiver.

Never changes the normal receiver or its profiles. Pairing data stays in subprocess
memory; only sanitized acceptance evidence is retained.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import importlib.util
import hashlib

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--host', type=Path, required=True)
parser.add_argument('--serial', required=True)
parser.add_argument('--adb', default='adb')
parser.add_argument('--real-pointer', action='store_true', help='Enable real output and verify focused AppKit pointer delivery')
parser.add_argument('--drop-udp', action='store_true', help='Drop datagrams after the first joystick and trigger downs')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
host = str(args.host.resolve())

def complete_rows(path):
    # Probe writes continue while evidence is read; ignore an incomplete final row.
    return [json.loads(line) for line in path.read_text().split('\n')[:-1] if line]

def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

with tempfile.TemporaryDirectory(prefix='thumble-advanced-') as directory:
    state_dir = Path(directory)
    env = dict(os.environ, THUMBLE_HOST_STATE_DIR=directory,
               THUMBLE_HOST_CONTROL_SOCKET=str(state_dir / 'control.sock'))
    def run(*command):
        result = subprocess.run([host, *command], env=env, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError('Private Rust receiver command failed')
        return result.stdout
    def status():
        value = json.loads(run('status', '--json'))
        return value.get('status', value.get('response', {}).get('status', value))
    profile_id = '77aa418b-aa10-4bb0-8220-6c23fed80200'
    elements = []
    for index, kind in enumerate(['joystick', 'trigger', 'trackpad']):
        element = dict(id=f'b979b12b-aa10-4bb0-8220-6c23fed8020{index+1}', kind=kind, label=kind,
                       layout=dict(centerX=.2+index*.3, centerY=.5, shape='rectangle'))
        if kind == 'joystick':
            element['joystickOutputSettings'] = dict(analogTarget='leftStick')
            element['partOutputs'] = ['joystick_right', dict(keyboard=dict(keyCode=12, modifiersRawValue=0))]
        if kind == 'trigger':
            element['triggerSettings'] = dict(target='right', sendsDigitalButton=True)
            element['partOutputs'] = ['trigger_digital', dict(keyboard=dict(keyCode=13, modifiersRawValue=0))]
        elements.append(element)
    profile = dict(id=profile_id, name='Android advanced acceptance', outputMode='custom',
                   orientationPreference='landscape', customization=dict(elements=elements))
    state = dict(schemaVersion=3, serverID='android-advanced-recorder', trustedClients={},
                 profiles=[profile], activeProfileID=profile_id, defaultProfileID=profile_id)
    (state_dir / 'state.json').write_text(json.dumps(state))
    (state_dir / 'state.json').chmod(0o600)
    started = False
    relay = None
    probe = None
    probe_log = state_dir / 'pointer-events.jsonl'
    try:
        run('start', '--port', '0', '--no-bonjour', *([] if args.real_pointer else ['--no-input']))
        started = True
        before = status()
        assert before['inputEnabled'] == args.real_pointer
        if args.real_pointer:
            assert before['accessibilityTrusted'], 'Installed host needs Accessibility permission'
            binary = state_dir / 'pointer-probe'
            subprocess.run(['clang', '-fobjc-arc', '-framework', 'Cocoa', '-framework', 'ApplicationServices',
                str(Path(__file__).with_name('pointer-probe.m')), '-o', str(binary)], check=True)
            probe = subprocess.Popen([str(binary), str(probe_log), str(before['pid'])])
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                assert probe.poll() is None, 'Pointer probe exited before focus'
                if probe_log.exists() and any(row.get('focused') for row in complete_rows(probe_log)):
                    break
                time.sleep(.1)
            else:
                raise AssertionError('Pointer probe did not acquire focus')
        port = before['port']
        # USB TCP forwarding is unsuitable for UDP; use the host's LAN endpoint.
        from urllib.parse import urlsplit
        import ipaddress
        urls = [url for url in before['urls'] if
                (lambda ip: ip.version == 4 and ip.is_private and not ip.is_loopback and not ip.is_link_local)(ipaddress.ip_address(urlsplit(url).hostname))]
        assert urls, 'Private receiver has no LAN address reachable from Android'
        if args.drop_udp:
            spec = importlib.util.spec_from_file_location('udp_drop_relay', Path(__file__).with_name('udp-drop-relay.py'))
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            relay = module.UDPDropRelay(port)
            urls = [f'ws://{urlsplit(url).hostname}:{relay.port}' for url in urls]
        qr = json.dumps(dict(type='pocketpad-pair', urls=urls, pairingCode=before['pairingCode'], serverID=before['serverID']))
        for apk in ['app/build/outputs/apk/debug/app-debug.apk', 'app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk']:
            subprocess.run([args.adb, '-s', args.serial, 'install', '-r', str(root / apk)], check=True, capture_output=True)
        result = subprocess.run([args.adb, '-s', args.serial, 'shell', 'am', 'instrument', '-w', '-r',
            '-e', 'class', 'com.thumble.android.AdvancedControlsDeviceTest#optionalRustAdvancedInterop',
            '-e', 'pointerDrag', str(args.real_pointer).lower(),
            '-e', 'advancedPairingQR', "'" + qr.replace("'", "'\\''") + "'",
            'com.thumble.android.test/androidx.test.runner.AndroidJUnitRunner'], capture_output=True, text=True)
        if result.returncode or 'OK (1 test)' not in result.stdout or 'FAILURES' in result.stdout:
            # Test assertions never include the pairing payload.
            print(result.stdout)
            raise RuntimeError('Android/Rust advanced interoperability failed')
        after = status()
        deadline = time.monotonic() + 5
        while after['core']['paired'] and time.monotonic() < deadline:
            time.sleep(.1)
            after = status()
        events = None
        if not args.real_pointer:
            records = [json.loads(line) for line in (state_dir / 'recorded-output.jsonl').read_text().splitlines()]
            events = [row['event'] for row in records]
            required = ['key_down:12:0', 'key_up:12:0', 'key_down:13:0', 'key_up:13:0',
                        'gamepad_stick:Left:', 'gamepad_trigger:Right:', 'pointer_move:',
                        'pointer_scroll:', 'pointer_down:left', 'pointer_up:left',
                        'pointer_down:right', 'pointer_up:right']
            missing = [prefix for prefix in required if not any(event.startswith(prefix) for event in events)]
            assert not missing, f'Missing recorded output paths: {missing}; events={events}'
            assert 'gamepad_stick:Left:0.000:0.000' in events
            assert 'gamepad_trigger:Right:0.000' in events
            for event, count in {'key_down:12:0': 2, 'key_up:12:0': 2, 'key_down:13:0': 1,
                                 'key_up:13:0': 1, 'pointer_down:left': 2, 'pointer_up:left': 2,
                                 'pointer_down:right': 1, 'pointer_up:right': 1}.items():
                assert events.count(event) == count, f'Duplicate or missing output: {event}'
            assert sum(event.startswith('pointer_move:') for event in events) == 1
            assert sum(event.startswith('pointer_scroll:') for event in events) == 1
        assert not after['core']['paired']
        assert not after['output']['heldKeyCount'] and not after['output']['heldPointerButtons']
        counters = after['core']['counters']
        assert counters['expiredHolds'] == 0
        assert counters['rejectedInputs'] == counters['staleGenerations']
        realtime = after['realtime']
        assert realtime['udpAcceptedInputs'] > 0 and realtime['websocketAcceptedInputs'] >= 6
        loss = relay.summary() if relay else None
        if loss:
            assert loss['distinctForwardedDowns'] == 2
            assert loss['droppedButtonUps'] >= 2 and loss['droppedDatagrams'] >= 6
        application_events = None
        if args.real_pointer:
            rows = complete_rows(probe_log)
            capture = root / f'app/build/evidence/pointer-appkit{"-drop" if relay else ""}-events.json'
            capture.parent.mkdir(parents=True, exist_ok=True)
            capture.write_text(json.dumps(rows, indent=2) + '\n')
            application_events = [row for row in rows if row['kind'] != 'focus']
            expected = [('down', 0), ('up', 0), ('down', 1), ('up', 1), ('down', 0), ('up', 0), ('down', 0), ('up', 0)]
            assert [(row['kind'], row['button']) for row in application_events if row['kind'] in ('down', 'up')] == expected, 'Missing or duplicate AppKit click edges'
            assert [row['kind'] for row in application_events] == ['move', 'down', 'up', 'scroll', 'down', 'up', 'down', 'up', 'down', 'drag', 'up'], 'Missing, duplicate or reordered AppKit delivery'
            assert any(row['kind'] == 'drag' and row['held'] == [0] for row in application_events), 'No held-button drag reached AppKit'
            assert any(row['kind'] == 'move' for row in application_events), 'No application pointer movement'
            assert any(row['kind'] == 'scroll' and (row['x'] or row['y']) for row in application_events), 'No application scroll'
            assert rows[-1]['kind'] == 'focus' and rows[-1]['focused'] and not rows[-1]['held'], 'Probe lost focus or retained a button'
        evidence = dict(device=args.serial, hostSHA256=sha256(host),
                        testAPKSHA256=sha256(root / 'app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk'),
                        pointerProbeSHA256=sha256(Path(__file__).with_name('pointer-probe.m')) if args.real_pointer else None, recordingOnly=not args.real_pointer, applicationEvents=application_events, receiverProcessFiltered=args.real_pointer, normalReceiverTouched=False, nativeGestureSurface=True,
                        udpAcceptedInputs=realtime['udpAcceptedInputs'], websocketAcceptedInputs=realtime['websocketAcceptedInputs'],
                        outputEvents=events, heldKeyCount=0, heldPointerButtons=[], counters=counters, packetLoss=loss)
        name = 'advanced-real-pointer' if args.real_pointer else 'advanced-rust'
        destination = root / f'app/build/evidence/{name}{"-drop" if relay else ""}-result.json'
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(json.dumps(evidence, indent=2) + '\n')
        print(f'Android native advanced gestures → Rust output passed; UDP={realtime["udpAcceptedInputs"]}, WebSocket={realtime["websocketAcceptedInputs"]}; no held inputs.')
        print(f'Evidence: {destination}')
    finally:
        if relay:
            relay.close()
        try:
            if started:
                try:
                    run('release-all')
                finally:
                    run('stop')
        finally:
            if probe is not None:
                probe.terminate()
                probe.wait(timeout=5)
