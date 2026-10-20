#!/usr/bin/env python3
"""Explicitly test the installed receiver: Android adoption, CLI replay and cancellation.

Creates two synthetic profiles, checks existing profiles/default remain intact,
then deletes only those synthetic IDs and restores the original selection.
Pairing credentials and trusted-client data are never copied to evidence.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import ipaddress
import json
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--adb', required=True)
    parser.add_argument('--installed-bin', type=Path, required=True)
    parser.add_argument('--receiver-host', help='Explicit Mac Wi-Fi IPv4 address; required for a physical phone')
    args = parser.parse_args()
    physical = not args.serial.startswith('emulator-')
    assert not physical or args.receiver_host, 'A physical phone requires an explicit Mac Wi-Fi address'
    receiver_host = args.receiver_host or '10.0.2.2'
    address = ipaddress.ip_address(receiver_host)
    assert address.version == 4 and address.is_private and not address.is_loopback and not address.is_unspecified and not address.is_multicast
    root = Path(__file__).resolve().parents[2]
    evidence = root / 'Android/app/build/evidence/installed-artifact-adoption' / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    evidence.mkdir(parents=True)
    state_file = args.installed_bin.parent / 'state.json'
    before = json.loads(state_file.read_text())
    old_ids = {p['id'].lower() for p in before['profiles']}
    adopted_ids = []
    base = [args.adb, '-s', args.serial]

    def adb(*values, check=True):
        result = subprocess.run(base + list(values), capture_output=True, text=True, timeout=40)
        if check and result.returncode:
            raise RuntimeError('Android command failed; pairing arguments withheld')
        return result

    def command(name, *values, success=True):
        result = subprocess.run([str(args.installed_bin / name), *values], capture_output=True, text=True, timeout=40)
        if (result.returncode == 0) != success:
            raise RuntimeError('Installed receiver/CLI command failed: ' + result.stderr[:200])
        return result

    def status():
        value = json.loads(command('thumble-host', 'status', '--json').stdout)
        return value.get('status', value)

    wifi_route = None
    if physical:
        wifi_route = adb('shell', 'ip', 'route', 'get', receiver_host).stdout.strip()
        assert 'dev wlan0' in wifi_route, 'Receiver traffic must use the phone Wi-Fi interface'
    model = adb('shell', 'getprop', 'ro.product.model').stdout.strip()
    sdk = adb('shell', 'getprop', 'ro.build.version.sdk').stdout.strip()

    live = status()
    assert live['inputEnabled'] and live['configurationWriteEnabled']
    assert live['output']['heldKeyCount'] == 0
    assert live['serverID'] == before['serverID']
    qr = json.dumps(dict(type='pocketpad-pair', urls=[f"ws://{receiver_host}:{live['port']}"], pairingCode=live['pairingCode'], serverID=live['serverID']))
    remote = '/sdcard/Android/data/com.thumble.android/files/shared-build-'
    for part, name in [('debug', 'app-debug.apk'), ('androidTest/debug', 'app-debug-androidTest.apk')]:
        adb('install', '-r', str(root / 'Android/app/build/outputs/apk' / part / name))
    for name in ['adoption-result', 'adoption-artifact', 'cli-cancel-ready', 'cancellation-result']:
        adb('shell', 'rm', '-f', remote + name + '.json')

    def instrument(test, filename, on_running=None):
        with (evidence / filename).open('w') as log:
            process = subprocess.Popen(base + ['shell', 'am', 'instrument', '-w', '-e', 'class', test,
                '-e', 'adoptionPairingQR', "'" + qr.replace("'", "'\\''") + "'",
                '-e', 'normalAdoptionServerID', live['serverID'],
                'com.thumble.android.test/androidx.test.runner.AndroidJUnitRunner'], stdout=log, stderr=log)
            try:
                if on_running:
                    on_running(process)
                code = process.wait(timeout=100)
            except Exception:
                adb('shell', 'am', 'force-stop', 'com.thumble.android', check=False)
                process.wait(timeout=10)
                raise
        assert code == 0 and 'OK (1 test)' in (evidence / filename).read_text(), 'Installed acceptance failed; see ' + str(evidence)

    cleanup_ok = False
    try:
        instrument('com.thumble.android.SharedBuildDeviceTest#realRustReceiverAdoptsReviewedBuildAndConfirmsAuthoritativeCopies', 'android-adoption.log')
        adb('pull', remote + 'adoption-result.json', str(evidence / 'android-result.json'))
        adb('pull', remote + 'adoption-artifact.json', str(evidence / 'artifact.json'))
        result = json.loads((evidence / 'android-result.json').read_text())
        adopted_ids = result['destinationProfileIDs']
        assert not old_ids.intersection(x.lower() for x in adopted_ids)
        after = json.loads(state_file.read_text())
        assert len(after['profiles']) == len(before['profiles']) + 2
        assert after['profiles'][:len(before['profiles'])] == before['profiles']
        assert after['defaultProfileID'] == before['defaultProfileID']
        replay_args = ['shared-build', 'adopt', str(evidence / 'artifact.json'), '--operation-id', result['operationID'],
                       '--record-id', result['recordID'], '--server-id', result['serverID'], '--json']
        replay = json.loads(command('thumble', *replay_args).stdout)
        assert replay['status'] == 'replayed'
        assert {x.lower() for x in replay['destinationProfileIDs']} == {x.lower() for x in adopted_ids}
        assert json.loads(state_file.read_text()) == after
        cli_status = json.loads(command('thumble', 'shared-build', 'status', result['operationID'], '--json').stdout)
        assert cli_status['status'] == 'replayed'
        # A late cancel must report the durable result, without deleting profiles.
        late = json.loads(command('thumble', 'shared-build', 'cancel', result['operationID'], '--json').stdout)
        assert late['status'] == 'replayed' and json.loads(state_file.read_text()) == after
        for name in ['native-adoption-review', 'native-adoption-confirmed']:
            adb('pull', remote + name + '.png', str(evidence / (name + '.png')))

        def cancel_pending(process):
            ready = evidence / 'cli-cancel-ready.json'
            deadline = time.monotonic() + 35
            while time.monotonic() < deadline and process.poll() is None:
                pulled = adb('pull', remote + 'cli-cancel-ready.json', str(ready), check=False)
                if pulled.returncode == 0:
                    break
                time.sleep(.15)
            assert ready.exists(), 'Android cancellation handshake did not arrive'
            metadata = json.loads(ready.read_text())
            assert metadata['intendedServerID'] == live['serverID']
            operation = metadata['operationID']
            pending = json.loads(command('thumble', 'shared-build', 'status', operation, '--json').stdout)
            assert pending['status'] == 'accepted'
            canceled = command('thumble', 'shared-build', 'cancel', operation, '--json', success=False)
            assert canceled.returncode != 0
            outcome = json.loads(canceled.stdout)
            assert outcome['status'] == 'failed' and outcome['errorCode'] == 'disconnected'
            (evidence / 'cli-cancellation.json').write_text(json.dumps(outcome, indent=2) + '\n')

        instrument('com.thumble.android.ProfileArtifactAdoptionDeviceTest#normalReceiverCancellationRetainsBuildAndCLICanCancelAPhoneUpload',
                   'android-cancellation.log', cancel_pending)
        adb('pull', remote + 'cancellation-result.json', str(evidence / 'android-cancellation.json'))
        current = json.loads(state_file.read_text())
        for field in ['profiles', 'activeProfileID', 'defaultProfileID', 'profileArtifactAdoptions', 'configurationRevision']:
            assert current[field] == after[field], 'Cancellation changed authority: ' + field
        assert status()['output']['heldKeyCount'] == 0
        report = dict(passed=True, receiver='normal-installed', realInputEnabled=True, originalProfilesPreserved=True,
                      physicalAndroid=physical, androidModel=model, androidSDK=sdk, receiverHost=receiver_host,
                      wifiRoute=wifi_route, applicationTransport='direct Wi-Fi' if physical else 'emulator host interface',
                      defaultPreserved=True, androidAdoption=True, cliReplay=True, cliStatus=True, lateCancelReplaysSuccess=True,
                      androidCancellation=True, cliCancellationDeliveredToAndroid=True, canceledBytesRetained=True,
                      cancellationDidNotChangeAuthority=True, originalProfileCount=len(before['profiles']),
                      installedHashes={name: hashlib.sha256((args.installed_bin / name).read_bytes()).hexdigest()
                          for name in ['thumble-host', 'thumble-bridge', 'thumble', 'thumble-cli-bridge']})
        report['androidHashes'] = {name: hashlib.sha256((root / 'Android/app/build/outputs/apk' / part / name).read_bytes()).hexdigest()
                                  for part, name in [('debug', 'app-debug.apk'), ('androidTest/debug', 'app-debug-androidTest.apk')]}
    finally:
        # Restore through the authority, never overwrite a live state file or
        # remove a profile not positively identified by this test's receipt.
        if adopted_ids:
            command('thumble', 'profile', 'select', before['activeProfileID'])
            command('thumble', 'profile', 'delete', *adopted_ids)
            restored = json.loads(state_file.read_text())
            cleanup_ok = restored['profiles'] == before['profiles'] and restored['activeProfileID'] == before['activeProfileID'] and restored['defaultProfileID'] == before['defaultProfileID']
            assert cleanup_ok, 'Original profile restoration needs inspection'
            for field in ['keyBindings', 'outputBindings', 'profileKeyBindings', 'profileOutputBindings']:
                assert restored.get(field, {}) == before.get(field, {}), 'Original binding restoration needs inspection: ' + field
    report['testProfilesRemovedAndSelectionRestored'] = cleanup_ok
    report['originalBindingMapsPreserved'] = cleanup_ok
    (evidence / 'acceptance.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(dict(passed=True, evidence=str(evidence))))


if __name__ == '__main__':
    main()
