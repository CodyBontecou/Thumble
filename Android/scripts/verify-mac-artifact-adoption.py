#!/usr/bin/env python3
"""Exercise Android's reviewed shared-build adoption against a private Rust receiver.

Uses current native validation and the public CLI. Never changes the installed
receiver or normal Mac profiles. Pairing credentials remain in memory.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--adb', default='adb')
    parser.add_argument('--bin', type=Path, required=True)
    args = parser.parse_args()
    assert args.serial.startswith('emulator-'), 'Requires a dedicated Android emulator'
    root = Path(__file__).resolve().parents[2]
    evidence = root / 'Android/app/build/evidence/artifact-adoption' / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    evidence.mkdir(parents=True)
    base = [args.adb, '-s', args.serial]

    def adb(*values):
        result = subprocess.run(base + list(values), capture_output=True, text=True, timeout=40)
        if result.returncode:
            raise RuntimeError('Android command failed; pairing arguments withheld')
        return result.stdout

    for apk in ['app-debug.apk', 'app-debug-androidTest.apk']:
        part = 'debug' if apk == 'app-debug.apk' else 'androidTest/debug'
        adb('install', '-r', str(root / 'Android/app/build/outputs/apk' / part / apk))
    with tempfile.TemporaryDirectory(prefix='thumble-adoption-') as temporary:
        folder = Path(temporary)
        binary = folder / 'bin'
        binary.mkdir(mode=0o700)
        names = ['thumble-host', 'thumble-bridge', 'thumble', 'thumble-cli-bridge']
        for name in names:
            shutil.copy2(args.bin / name, binary / name)
        state = folder / 'state'
        state.mkdir(mode=0o700)
        env = dict(os.environ, THUMBLE_HOST_STATE_DIR=str(state), THUMBLE_HOST_CONTROL_SOCKET=str(folder / 'control.sock'))
        profile = json.loads((root / 'Host/fixtures/state/minimal-profile.json').read_text())
        profile['orientationPreference'] = 'portrait'
        initial = dict(schemaVersion=3, configurationRevision=1, serverID='adoption-' + str(uuid.uuid4()), trustedClients={},
                       profiles=[profile], activeProfileID=profile['id'], defaultProfileID=profile['id'])
        saved = state / 'state.json'
        saved.write_text(json.dumps(initial))
        saved.chmod(0o600)

        def host(*values, executable='thumble-host'):
            result = subprocess.run([str(binary / executable), *values], env=env, capture_output=True, text=True, timeout=40)
            if result.returncode:
                raise RuntimeError('Private receiver/CLI command failed: ' + result.stderr[:300])
            return result.stdout

        started = False
        try:
            host('start', '--port', '0', '--no-input', '--no-bonjour', '--allow-config-write')
            started = True
            status = json.loads(host('status', '--json'))
            status = status.get('status', status)
            assert status['inputEnabled'] is False
            qr = json.dumps(dict(type='pocketpad-pair', urls=[f"ws://10.0.2.2:{status['port']}"],
                                 pairingCode=status['pairingCode'], serverID=status['serverID']))
            remote = '/sdcard/Android/data/com.thumble.android/files/shared-build-'
            adb('shell', 'rm', '-f', remote + 'adoption-result.json', remote + 'adoption-artifact.json')
            with (evidence / 'instrumentation.log').open('w') as log:
                try:
                    completed = subprocess.run(base + ['shell', 'am', 'instrument', '-w', '-e', 'class',
                        'com.thumble.android.SharedBuildDeviceTest#realRustReceiverAdoptsReviewedBuildAndConfirmsAuthoritativeCopies',
                        '-e', 'adoptionPairingQR', "'" + qr.replace("'", "'\\''") + "'",
                        'com.thumble.android.test/androidx.test.runner.AndroidJUnitRunner'], stdout=log, stderr=log, timeout=150)
                except subprocess.TimeoutExpired:
                    adb('shell', 'am', 'force-stop', 'com.thumble.android')
                    raise RuntimeError('Adoption acceptance timed out; pairing arguments withheld') from None
            report = (evidence / 'instrumentation.log').read_text()
            assert completed.returncode == 0 and 'OK (1 test)' in report, 'Android adoption failed; see ' + str(evidence)
            adb('pull', remote + 'adoption-result.json', str(evidence / 'android-result.json'))
            adb('pull', remote + 'adoption-artifact.json', str(evidence / 'artifact.json'))
            result = json.loads((evidence / 'android-result.json').read_text())
            final = json.loads(saved.read_text())
            assert len(final['profiles']) == 3 and final['profiles'][0] == profile
            assert final['defaultProfileID'] == initial['defaultProfileID']
            assert final['activeProfileID'].lower() == result['destinationProfileIDs'][0].lower()
            assert len(final['profileArtifactAdoptions']) == 1
            receipt = final['profileArtifactAdoptions'][0]
            assert receipt['metadata']['operationID'].lower() == result['operationID'].lower()
            assert receipt['metadata']['rawSHA256'] == result['rawSHA256']
            assert receipt['result']['status'] == 'succeeded'
            replay_args = ['shared-build', 'adopt', str(evidence / 'artifact.json'), '--operation-id', result['operationID'],
                           '--record-id', result['recordID'], '--server-id', result['serverID'], '--json']
            replay = json.loads(host(*replay_args, executable='thumble'))
            assert replay['status'] == 'replayed' and json.loads(saved.read_text()) == final
            current = json.loads(host('status', '--json'))
            current = current.get('status', current)
            assert current['output']['heldKeyCount'] == 0
            host('stop')
            started = False
            host('start', '--port', '0', '--no-input', '--no-bonjour', '--allow-config-write')
            started = True
            replay = json.loads(host(*replay_args, executable='thumble'))
            assert replay['status'] == 'replayed' and json.loads(saved.read_text()) == final
            for name in ['native-adoption-review', 'native-adoption-confirmed']:
                adb('pull', remote + name + '.png', str(evidence / (name + '.png')))
            checks = dict(passed=True, normalMacInstallationChanged=False, inputEnabled=False, heldKeys=0,
                          nativeProfileCopies=2, defaultPreserved=True, authoritativeSnapshotConfirmed=True,
                          pendingBuildDeletedAfterConfirmation=True, publicCLIReplay=True, restartReplay=True,
                          hashes={name: hashlib.sha256((args.bin / name).read_bytes()).hexdigest() for name in names})
            for part, name in [('debug', 'app-debug.apk'), ('androidTest/debug', 'app-debug-androidTest.apk')]:
                checks['hashes'][name] = hashlib.sha256((root / 'Android/app/build/outputs/apk' / part / name).read_bytes()).hexdigest()
            (evidence / 'acceptance.json').write_text(json.dumps(checks, indent=2) + '\n')
            print(json.dumps(dict(passed=True, evidence=str(evidence))))
        finally:
            if started:
                host('stop')


if __name__ == '__main__':
    main()
