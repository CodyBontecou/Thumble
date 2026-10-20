#!/usr/bin/env python3
"""USB-controlled physical Wi-Fi loss at two real-receiver adoption boundaries.

The phone-local test relay gates an incomplete upload or a committed response.
Wi-Fi is actually disabled; upstream ping I/O failure must reach the production
client and pending-build coordinator. No receiver fault hooks are required.
Credentials remain in memory. Only test-operation receipts identify cleanup IDs.
"""
import argparse
from datetime import datetime, timezone
import ipaddress
import os
import json
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--adb', required=True)
    parser.add_argument('--installed-bin', type=Path, required=True)
    parser.add_argument('--receiver-host', required=True)
    parser.add_argument('--isolated', action='store_true', help='Permit recording mode only for an explicitly isolated receiver')
    args = parser.parse_args()
    assert not args.serial.startswith('emulator-'), 'Requires USB-connected physical Android'
    address = ipaddress.ip_address(args.receiver_host)
    assert address.version == 4 and address.is_private and not address.is_loopback and not address.is_unspecified and not address.is_multicast
    root = Path(__file__).resolve().parents[2]
    evidence = root / 'Android/app/build/evidence/wifi-adoption-recovery' / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    evidence.mkdir(parents=True)
    state_file = args.installed_bin.parent / 'state.json'
    before = json.loads(state_file.read_text())
    original_ids = {p['id'].lower() for p in before['profiles']}
    remote = '/sdcard/Android/data/com.thumble.android/files/wifi-'
    base = [args.adb, '-s', args.serial]
    operations = []
    cases = []
    radio_touched = False

    def adb(*values, check=True):
        result = subprocess.run(base + list(values), capture_output=True, text=True, timeout=40)
        if check and result.returncode:
            raise RuntimeError('Android command failed (credential-bearing arguments withheld)')
        return result

    def cli(*values, check=True):
        result = subprocess.run([str(args.installed_bin / 'thumble'), *values], capture_output=True, text=True, timeout=40)
        if check:
            assert result.returncode == 0, 'Public CLI failed: ' + result.stderr[:500]
        return json.loads(result.stdout) if '--json' in values and result.stdout.strip() else {}

    def route():
        return adb('shell', 'ip', 'route', 'get', args.receiver_host, check=False).stdout.strip()

    def wait_for(label, predicate, timeout=40):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            time.sleep(.2)
        raise AssertionError(label)

    def pull(mode, name):
        path = evidence / f'{mode}-{name}.json'
        result = adb('pull', remote + f'{mode}-{name}.json', str(path), check=False)
        return json.loads(path.read_text()) if result.returncode == 0 else None

    def wifi_on():
        adb('shell', 'svc', 'wifi', 'enable')
        return wait_for('Wi-Fi route did not recover', lambda: route() if 'dev wlan0' in route() else None, 60)

    assert 'dev wlan0' in route(), 'Receiver must be reached over physical Wi-Fi'
    assert adb('shell', 'cmd', 'wifi', 'status').stdout.startswith('Wifi is enabled')
    live_result = subprocess.run([str(args.installed_bin / 'thumble-host'), 'status', '--json'], capture_output=True, text=True, timeout=20)
    assert live_result.returncode == 0
    live = json.loads(live_result.stdout);live = live.get('status', live)
    assert live['serverID'] == before['serverID'] and live['configurationWriteEnabled']
    if args.isolated:
        assert before['serverID'].startswith('adoption-isolated-')
        assert Path(os.environ['THUMBLE_HOST_STATE_DIR']).resolve() == args.installed_bin.parent.resolve()
    else:
        assert live['inputEnabled']
    assert live['output']['heldKeyCount'] == 0
    qr = json.dumps(dict(type='pocketpad-pair', urls=[f"ws://{args.receiver_host}:{live['port']}"], pairingCode=live['pairingCode'], serverID=live['serverID']))
    adb('install', '-r', str(root / 'Android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk'))
    try:
        for mode in ['partial', 'committed']:
            for name in ['checkpoint', 'retained', 'reconnect', 'result', 'artifact']:
                adb('shell', 'rm', '-f', remote + f'{mode}-{name}.json')
            baseline = json.loads(state_file.read_text())
            with (evidence / f'{mode}-instrumentation.log').open('w') as log:
                process = subprocess.Popen(base + ['shell', 'am', 'instrument', '-w', '-e', 'class',
                    'com.thumble.android.WifiAdoptionRecoveryDeviceTest#physicalWifiLossRetainsBuildAndRetryIsIdempotent',
                    '-e', 'adoptionPairingQR', "'" + qr.replace("'", "'\\''") + "'", '-e', 'normalAdoptionServerID', live['serverID'],
                    '-e', 'wifiRecoveryMode', mode, 'com.thumble.android.test/androidx.test.runner.AndroidJUnitRunner'], stdout=log, stderr=log)
                try:
                    checkpoint = wait_for('Adoption checkpoint missing', lambda: pull(mode, 'checkpoint') if process.poll() is None else None)
                    metadata = checkpoint['metadata'];operations.append(metadata['operationID'])
                    assert metadata['intendedServerID'] == live['serverID']
                    at_drop = json.loads(state_file.read_text())
                    count = len(at_drop['profiles']) - len(baseline['profiles'])
                    assert count == (0 if mode == 'partial' else 1)
                    radio_touched = True
                    adb('shell', 'svc', 'wifi', 'disable')
                    wait_for('Wi-Fi radio did not turn off', lambda: adb('shell', 'cmd', 'wifi', 'status').stdout.startswith('Wifi is disabled'))
                    off_route = wait_for('Wi-Fi route survived radio disable', lambda: (route() or 'unreachable') if 'dev wlan0' not in route() else None)
                    retained = wait_for('Phone failed to retain interrupted adoption', lambda: pull(mode, 'retained') if process.poll() is None else None)
                    assert retained['bytesRetained'] and retained['pendingCount'] == 1 and retained['metadata'] == metadata
                    offline = json.loads(state_file.read_text())
                    for field in ['profiles', 'activeProfileID', 'defaultProfileID', 'profileArtifactAdoptions', 'configurationRevision']:
                        assert (offline.get(field, []) == at_drop.get(field, []) if field == 'profileArtifactAdoptions' else offline[field] == at_drop[field]), 'Offline failure changed Mac authority: ' + field
                    recovered_route = wifi_on()
                    adb('shell', 'touch', remote + f'{mode}-reconnect.json')
                    code = process.wait(timeout=80)
                    assert code == 0 and 'OK (1 test)' in (evidence / f'{mode}-instrumentation.log').read_text(), 'Device recovery test failed: ' + mode
                finally:
                    if process.poll() is None:
                        adb('shell', 'am', 'force-stop', 'com.thumble.android', check=False)
                        process.wait(timeout=10)
                    if radio_touched:
                        wifi_on()
                result = pull(mode, 'result');assert result and result['metadata'] == metadata
                artifact_path = evidence / f'{mode}-artifact.json'
                adb('pull', remote + f'{mode}-artifact.json', str(artifact_path))
                current = json.loads(state_file.read_text())
                assert current['profiles'][:len(baseline['profiles'])] == baseline['profiles']
                assert len(current['profiles']) == len(baseline['profiles']) + 1
                assert current['defaultProfileID'] == before['defaultProfileID']
                replay = cli('shared-build', 'adopt', str(artifact_path), '--operation-id', metadata['operationID'],
                             '--record-id', metadata['recordID'], '--server-id', live['serverID'], '--json')
                assert replay['status'] == 'replayed'
                assert {x.lower() for x in replay['destinationProfileIDs']} == {x.lower() for x in result['destinationProfileIDs']}
                if mode == 'committed':
                    assert replay['destinationProfileIDs'] == checkpoint['result']['destinationProfileIDs']
                assert json.loads(state_file.read_text()) == current, 'CLI replay changed authority'
                cases.append(dict(mode=mode, realRadioDisabled=True, offlineRoute=off_route, recoveredRoute=recovered_route,
                                  bytesRetained=True, stableOperationRecordAndHashes=True, newProfilesExactlyOne=True,
                                  pendingRemovedAfterConfirmation=True, cliReplayNoDuplicates=True))
    finally:
        if radio_touched:
            wifi_on()
        # Recover receipts even if the device test failed after the Mac committed.
        for mode in ['partial', 'committed']:
            checkpoint = pull(mode, 'checkpoint')
            if checkpoint and checkpoint['metadata']['operationID'] not in operations:
                operations.append(checkpoint['metadata']['operationID'])
        ids = set()
        for operation in operations:
            receipt = cli('shared-build', 'status', operation, '--json', check=False)
            for value in receipt.get('destinationProfileIDs', []):
                assert value.lower() not in original_ids
                ids.add(value)
        if ids:
            cli('profile', 'select', before['activeProfileID'])
            cli('profile', 'delete', *sorted(ids))
        restored = json.loads(state_file.read_text())
        for field in ['profiles', 'activeProfileID', 'defaultProfileID', 'keyBindings', 'outputBindings', 'profileKeyBindings', 'profileOutputBindings']:
            assert restored.get(field, {}) == before.get(field, {}), 'Original setup not restored: ' + field
    report = dict(passed=True, physicalDevice=args.serial, receiver='isolated' if args.isolated else 'normal-installed', receiverHost=args.receiver_host,
                  faultInjection='phone-local boundary relay; actual upstream Wi-Fi radio loss', cases=cases,
                  originalProfilesBindingsDefaultSelectionRestored=True, wifiRestored=True)
    (evidence / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(dict(passed=True, evidence=str(evidence))))


if __name__ == '__main__':
    main()
