#!/usr/bin/env python3
"""Force-stop and relaunch physical Android during real Mac shared-build adoption.

Uses two distinct instrumentation processes and an isolated production disk store.
The preparer gates an upload/confirmation, then is killed without orderly cleanup.
The new process launches MainActivity, reloads encrypted credentials and pending
bytes, and retries through the real UI. Only receipt-identified profiles are removed.
"""
import argparse
from datetime import datetime, timezone
import ipaddress
import os
import json
from pathlib import Path
import subprocess
import time
import hashlib
import uuid


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
    evidence = root / 'Android/app/build/evidence/process-death-adoption' / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    evidence.mkdir(parents=True)
    state_file = args.installed_bin.parent / 'state.json'
    before = json.loads(state_file.read_text())
    original_ids = {p['id'].lower() for p in before['profiles']}
    remote = '/sdcard/Android/data/com.thumble.android/files/death-'
    base = [args.adb, '-s', args.serial]
    operations = []
    cases = []

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
    active = None
    run_ids = []
    try:
        for mode in ['partial', 'committed']:
            run_id = str(uuid.uuid4());run_ids.append(run_id)
            for name in ['before', 'checkpoint', 'result', 'artifact']:
                adb('shell', 'rm', '-f', remote + f'{mode}-{name}.json')
            baseline = json.loads(state_file.read_text())
            common = ['-e', 'processDeathRunID', run_id, '-e', 'wifiRecoveryMode', mode]
            runner = 'com.thumble.android.test/androidx.test.runner.AndroidJUnitRunner'
            with (evidence / f'{mode}-prepare.log').open('w') as log:
                active = subprocess.Popen(base + ['shell', 'am', 'instrument', '-w', '-e', 'class',
                    'com.thumble.android.WifiAdoptionRecoveryDeviceTest#prepareForProcessDeathDuringAdoption',
                    '-e', 'adoptionPairingQR', "'" + qr.replace("'", "'\\''") + "'", '-e', 'normalAdoptionServerID', live['serverID'],
                    *common, runner], stdout=log, stderr=log)
                checkpoint = wait_for('Prepared adoption checkpoint missing', lambda: pull(mode, 'checkpoint') if active.poll() is None else None)
                metadata = checkpoint['metadata'];operations.append(metadata['operationID'])
                assert checkpoint['runID'] == run_id and metadata['intendedServerID'] == live['serverID']
                at_kill = json.loads(state_file.read_text())
                assert len(at_kill['profiles']) == len(baseline['profiles']) + (0 if mode == 'partial' else 1)
                pid = checkpoint['pid']
                assert str(pid) in adb('shell', 'pidof', 'com.thumble.android').stdout.split()
                adb('shell', 'am', 'force-stop', 'com.thumble.android')
                wait_for('Android process survived force-stop', lambda: not adb('shell', 'pidof', 'com.thumble.android', check=False).stdout.strip())
                active.wait(timeout=20);active = None
            # Inspect persisted bytes while NO application process exists. Neither
            # the host nor a graceful lifecycle callback marks this record failed.
            record_id = str(uuid.UUID(metadata['recordID']))
            private = f'no_backup/process-adoption-{run_id}-pending/{record_id}'
            disk = json.loads(adb('shell', 'run-as', 'com.thumble.android', 'cat', private + '.metadata.json').stdout)
            blob = subprocess.run(base + ['exec-out', 'run-as', 'com.thumble.android', 'cat', private + '.artifact.json'], capture_output=True, timeout=30)
            assert blob.returncode == 0 and hashlib.sha256(blob.stdout).hexdigest() == metadata['rawSHA256']
            assert disk['state'] == 'ADOPTING' and disk['operationID'] == metadata['operationID']
            (evidence / f'{mode}-after-kill.json').write_text(json.dumps(dict(processAbsent=True, diskState=disk['state'],
                bytes= len(blob.stdout), rawSHA256=metadata['rawSHA256'], operationID=metadata['operationID']), indent=2) + '\n')
            stopped = json.loads(state_file.read_text())
            for field in ['profiles', 'activeProfileID', 'defaultProfileID', 'profileArtifactAdoptions', 'configurationRevision']:
                assert (stopped.get(field, []) == at_kill.get(field, []) if field == 'profileArtifactAdoptions' else stopped[field] == at_kill[field]), 'Killing Android changed Mac authority: ' + field
            with (evidence / f'{mode}-relaunch.log').open('w') as log:
                active = subprocess.Popen(base + ['shell', 'am', 'instrument', '-w', '-e', 'class',
                    'com.thumble.android.ProcessDeathAdoptionDeviceTest#relaunchReloadsInterruptedBuildAndUIRetryConfirmsExactlyOneCopy',
                    *common, runner], stdout=log, stderr=log)
                code = active.wait(timeout=110);active = None
                assert code == 0 and 'OK (1 test)' in (evidence / f'{mode}-relaunch.log').read_text(), 'Relaunch/retry test failed: ' + mode
            result = pull(mode, 'result');assert result and result['metadata'] == metadata
            assert result['pid'] != pid and result['previousPID'] == pid
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
            for name in ['retained', 'confirmed']:
                adb('pull', remote + f'{mode}-{name}.png', str(evidence / f'{mode}-{name}.png'))
            cases.append(dict(mode=mode, processKilled=True, newProcessPID=result['pid'], previousPID=pid,
                              diskStateWhileDead='ADOPTING', recoveredState=result['recoveredState'],
                              bytesSurvived=True, trustedCredentialsReloaded=True, stableOperationRecordAndHashes=True,
                              newProfilesExactlyOne=True, pendingRemovedAfterConfirmation=True, cliReplayNoDuplicates=True))
    finally:
        if active is not None and active.poll() is None:
            adb('shell', 'am', 'force-stop', 'com.thumble.android', check=False)
            active.wait(timeout=20)
        for mode in ['partial', 'committed']:
            checkpoint = pull(mode, 'checkpoint')
            if checkpoint and checkpoint.get('runID') in run_ids and checkpoint['metadata']['operationID'] not in operations:
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
        # Only this run's UUID directories are removed; the normal pending library
        # and session are never read, replaced, or cleared by the harness.
        for run_id in run_ids:
            for kind in ['pending', 'session']:
                adb('shell', 'run-as', 'com.thumble.android', 'rm', '-rf', f'no_backup/process-adoption-{run_id}-{kind}', check=False)
    report = dict(passed=True, physicalDevice=args.serial, receiver='isolated' if args.isolated else 'normal-installed', receiverHost=args.receiver_host,
                  faultInjection='phone-local boundary relay; actual Android force-stop and fresh process UI retry',
                  cases=cases, originalProfilesBindingsDefaultSelectionRestored=True, wifiUnchanged=True)
    (evidence / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(dict(passed=True, evidence=str(evidence))))


if __name__ == '__main__':
    main()
