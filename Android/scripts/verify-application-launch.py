#!/usr/bin/env python3
"""Verify installed-target launching via Rust CLI and Android using a temporary Mac app.

Normal receiver state and installed binaries are untouched. No input injection is
needed. Pairing payloads and bookmark data stay in subprocess memory/private state.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--host', type=Path, required=True)
parser.add_argument('--serial', required=True)
parser.add_argument('--cli', type=Path, help='Staged Swift thumble CLI with its sibling Rust CLI bridge')
parser.add_argument('--fixture-host', type=Path, help='Same-process scoped-bookmark harness; defaults to host sibling examples directory')
parser.add_argument('--adb', default='adb')
parser.add_argument('--targets', nargs='+', choices=['path','bookmark','foreign-bookmark-fallback','bundle','missing'], default=['path','bookmark','foreign-bookmark-fallback','bundle','missing'])
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
host = str(args.host.resolve())
fixture_host = (args.fixture_host or args.host.resolve().parent / 'examples/application_launch_fixture').resolve()
if 'bookmark' in args.targets:
    assert fixture_host.is_file(), 'Build thumble-host --example application_launch_fixture first'
lsregister = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
fixture_parent = root.parent / 'build/AndroidLaunchAcceptance'
fixture_parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='run-', dir=fixture_parent) as directory:
    folder = Path(directory)
    app = folder / 'Launch $(literal) fixture.app'
    macos = app / 'Contents/MacOS'
    resources = app / 'Contents/Resources'
    macos.mkdir(parents=True)
    resources.mkdir()
    binary = macos / 'LaunchFixture'
    bundle = 'com.thumble.launch-fixture.' + uuid.uuid4().hex
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier=bundle,
        CFBundleExecutable='LaunchFixture', CFBundleName='Thumble Launch Fixture',
        CFBundlePackageType='APPL', CFBundleInfoDictionaryVersion='6.0',
        CFBundleSupportedPlatforms=['MacOSX'], NSPrincipalClass='NSApplication', CFBundleVersion='1', CFBundleShortVersionString='1.0', NSHighResolutionCapable=True)))
    subprocess.run(['clang', '-fobjc-arc', '-framework', 'Cocoa', '-framework', 'CoreServices', str(Path(__file__).with_name('launch-fixture.m')), '-o', str(binary)], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], capture_output=True, check=True)
    bookmark = subprocess.run([str(binary), '--bookmark', str(app)], capture_output=True, text=True, check=True).stdout.strip()
    registration = subprocess.run([str(binary), '--register', str(app)], capture_output=True, text=True, check=True)
    assert registration.stdout.strip() == '0', 'Native LaunchServices registration failed: ' + registration.stdout.strip()
    lookup = 'missing'
    deadline = time.monotonic() + 3
    while lookup != 'found' and time.monotonic() < deadline:
        lookup = subprocess.run([str(binary), '--lookup', bundle], capture_output=True, text=True, check=True).stdout.strip()
        if lookup != 'found':
            time.sleep(.05)
    if lookup != 'found':
        subprocess.run([lsregister, '-u', str(app)], capture_output=True)
        known = subprocess.run([str(binary), '--lookup', 'com.apple.calculator'], capture_output=True, text=True, check=True).stdout.strip()
        raise AssertionError(f'Native fixture registration failed: lookup={lookup!r}, known={known!r}, registration=' + registration.stdout[:300] + registration.stderr[:300])
    receipt_file = folder / 'receipt.json'
    base = [args.adb, '-s', args.serial]
    outcomes = []
    cli_home = Path(tempfile.mkdtemp(prefix='c', dir=root.parent / 'build')) if args.cli else None
    try:
        for apk in ['app/build/outputs/apk/debug/app-debug.apk', 'app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk']:
            subprocess.run(base + ['install', '-r', str(root / apk)], capture_output=True, check=True)
        cases = [('path', dict(filePath=str(app))),
                 ('bookmark', dict(bookmarkData=bookmark, filePath='/missing/fallback.app')),
                 ('foreign-bookmark-fallback', dict(bookmarkData=bookmark, filePath=str(app))),
                 ('bundle', dict(filePath='/missing/fallback.app', bundleIdentifier=bundle)),
                 ('missing', dict(filePath='/missing/application.app'))]
        for case_index, (label, metadata) in enumerate(cases):
            if label not in args.targets:
                continue
            print('Testing target resolution: ' + label, flush=True)
            state_dir = (cli_home / 'Library/Application Support/ThumbleHost') if cli_home else folder / f'case{case_index}'
            state_dir.mkdir(parents=True, exist_ok=True)
            assert len(str(state_dir / 'control.sock').encode()) < 104, 'Private socket path is too long'
            state_file = state_dir / 'state.json'
            profile = copy.deepcopy(json.loads((root.parent / 'Host/fixtures/controller-templates/v1/productivityStarter.json').read_text())['profile'])
            profile['name'] = 'Android launch acceptance'
            profile['launchTarget'] = dict(kind='application', displayName='Launch fixture', **metadata)
            state_file.write_text(json.dumps(dict(schemaVersion=3, configurationRevision=1, serverID='android-launch-fixture', trustedClients={},
                profiles=[profile], activeProfileID=profile['id'], defaultProfileID=profile['id'])))
            state_file.chmod(0o600)
            env = dict(os.environ, THUMBLE_HOST_STATE_DIR=str(state_dir), THUMBLE_HOST_CONTROL_SOCKET=str(state_dir / 'control.sock'))
            def run(*command):
                result = subprocess.run([host, *command], env=env, capture_output=True, text=True, check=True)
                return json.loads(result.stdout) if '--json' in command else result.stdout
            def status():
                value = run('status', '--json')
                return value.get('status', value.get('response', {}).get('status', value))
            def wait_outcome(should_launch):
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    s = status()
                    launch = s.get('applicationLaunch') or {}
                    if launch.get('phase') in ('launched', 'failed'):
                        assert launch['phase'] == ('launched' if should_launch else 'failed'), f'Unexpected launch outcome: case={label}, code={launch.get("errorCode")}'
                        if should_launch and not receipt_file.exists():
                            time.sleep(.05)
                            continue
                        if should_launch:
                            receipt = json.loads(receipt_file.read_text())
                            assert receipt['bundleID'] == bundle and receipt['active'], 'Fixture did not launch and activate'
                            # A receipt is not proof that the self-exiting app
                            # stopped. Observe its exact PID before the next case.
                            exited = time.monotonic() + 5
                            while time.monotonic() < exited:
                                try:
                                    os.kill(receipt['pid'], 0)
                                except ProcessLookupError:
                                    break
                                time.sleep(.05)
                            else:
                                raise AssertionError('Fixture application did not exit')
                        else:
                            assert launch['errorCode'] == 'application_not_found' and not receipt_file.exists()
                        assert not s['output']['heldKeyCount'] and not s['output']['heldPointerButtons']
                        return
                    time.sleep(.05)
                raise AssertionError(f'Application launch did not complete: case={label}, phase={launch.get("phase")}, receipt={receipt_file.exists()}')
            started = False
            fixture_process = None
            try:
                if label == 'bookmark':
                    fixture_process = subprocess.Popen([str(fixture_host)], env=dict(env, THUMBLE_TEST_APPLICATION=str(app)), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    deadline = time.monotonic() + 10
                    while time.monotonic() < deadline:
                        assert fixture_process.poll() is None, 'Scoped-bookmark fixture receiver exited'
                        try:
                            ready = status()
                            if 'inputEnabled' in ready and ready.get('port'):
                                break
                        except subprocess.CalledProcessError:
                            time.sleep(.05)
                    else:
                        raise AssertionError('Scoped-bookmark fixture receiver did not start')
                else:
                    run('start', '--port', '0', '--no-input', '--no-bonjour')
                started = True
                before = status()
                assert not before['inputEnabled']
                original = json.loads(state_file.read_text())
                receipt_file.unlink(missing_ok=True)
                if label == 'path':
                    queued = run('launch-profile', '--json')['applicationLaunch']
                    assert queued['phase'] == 'resolving'
                    wait_outcome(True)
                    outcomes.append(dict(source='local-cli', target='path', launched=True, activated=True))
                    print('Local CLI launch/activation passed',flush=True)
                    receipt_file.unlink()
                    if args.cli:
                        # Child-only home scopes the helper's canonical authority
                        # discovery. The caller's environment/home are unchanged.
                        cli_env = dict(os.environ, HOME=str(cli_home))
                        for selector in ['active', 'default', profile['id'], profile['name']]:
                            launched = subprocess.run([str(args.cli.resolve()), 'profile', 'launch', selector, '--json'],
                                env=cli_env, capture_output=True, text=True, check=True)
                            response = json.loads(launched.stdout)
                            assert response['owner'] == 'rust' and response['response']['applicationLaunch']['phase'] == 'resolving'
                            wait_outcome(True)
                            outcomes.append(dict(source='swift-cli', selector=selector if selector in ['active','default'] else ('uuid' if selector == profile['id'] else 'name'), launched=True, activated=True))
                            receipt_file.unlink()
                        print('Swift CLI launch selectors passed',flush=True)
                if args.serial.startswith('emulator-'):
                    urls = [f"ws://10.0.2.2:{before['port']}"]
                else:
                    import ipaddress
                    from urllib.parse import urlsplit
                    urls = [url for url in before['urls'] if (lambda ip: ip.version == 4 and ip.is_private and not ip.is_loopback and not ip.is_link_local)(ipaddress.ip_address(urlsplit(url).hostname))]
                assert urls
                qr = json.dumps(dict(type='pocketpad-pair', urls=urls, pairingCode=before['pairingCode'], serverID=before['serverID']))
                instrument = subprocess.Popen(base + ['shell', 'am', 'instrument', '-w', '-r', '-e', 'class',
                    'com.thumble.android.ProfileActionsDeviceTest#optionalRustApplicationLaunchInterop',
                    '-e', 'applicationLaunchPairingQR', "'" + qr.replace("'", "'\\''") + "'",
                    'com.thumble.android.test/androidx.test.runner.AndroidJUnitRunner'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                saw_hold = False
                saw_release_while_paired = False
                saw_missing_preserve_hold = False
                deadline = time.monotonic() + 30
                previous_launch = before.get('applicationLaunch') or {}
                while instrument.poll() is None and time.monotonic() < deadline:
                    current = status()
                    paired = current['core']['paired']
                    held = current['output']['heldKeyCount']
                    launch = current.get('applicationLaunch') or {}
                    saw_hold |= paired and held > 0
                    fresh = launch.get('launchID') != previous_launch.get('launchID')
                    saw_release_while_paired |= paired and fresh and saw_hold and launch.get('phase') == 'launched' and held == 0
                    saw_missing_preserve_hold |= paired and fresh and held > 0 and launch.get('phase') == 'failed'
                    time.sleep(.025)
                if instrument.poll() is None:
                    instrument.terminate()
                    instrument.communicate(timeout=5)
                    raise AssertionError('Android launch instrumentation timed out')
                output, _ = instrument.communicate(timeout=5)
                result = subprocess.CompletedProcess(instrument.args, instrument.returncode, output)
                if result.returncode or 'OK (1 test)' not in result.stdout or 'FAILURES' in result.stdout:
                    print(result.stdout)
                    raise AssertionError('Android launch interoperability failed')
                assert saw_hold, 'No pre-launch held key observed'
                assert saw_missing_preserve_hold if label == 'missing' else saw_release_while_paired, 'Incorrect input neutralization during launch'
                wait_outcome(label != 'missing')
                saved = json.loads(state_file.read_text())
                assert saved['profiles'] == original['profiles']
                assert saved['configurationRevision'] == original['configurationRevision']
                print('Android launch/activation passed: ' + label, flush=True)
                outcomes.append(dict(source='android', target=label, launched=label != 'missing',
                    activated=label != 'missing', connectionPreserved=True, profileUnchanged=True,
                    heldInputObserved=True, releasedWhilePaired=saw_release_while_paired, missingTargetPreservedHold=saw_missing_preserve_hold))
            finally:
                try:
                    if started:
                        run('stop')
                finally:
                    if fixture_process is not None:
                        if not started:
                            fixture_process.terminate()
                        try:
                            fixture_process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            # The exact child remains live, e.g. startup failed
                            # before it published its control socket.
                            fixture_process.terminate()
                            fixture_process.wait(timeout=5)
    finally:
        subprocess.run([lsregister, '-u', str(app)], capture_output=True)
        if cli_home is not None:
            shutil.rmtree(cli_home)
    evidence = dict(cases=outcomes, sourceSHA256={name: hashlib.sha256((root.parent / name).read_bytes()).hexdigest() for name in ['Host/crates/thumble-host/src/cli_profile.rs','Host/crates/thumble-host/src/control.rs','Host/crates/thumble-cli-bridge/src/runtime.rs','Sources/CLI/ThumbleCLI.swift','Sources/CLI/ThumbleCLIRuntimeBackend.swift','Host/crates/thumble-host/src/application_launch.rs','Host/crates/thumble-host/src/platform/macos.rs','Host/crates/thumble-host/src/runtime.rs','Host/crates/thumble-host/examples/application_launch_fixture.rs','Android/scripts/launch-fixture.m','Android/scripts/verify-application-launch.py']}, receiverInputEnabled=False, normalReceiverTouched=False,
        bookmarkHarnessSHA256=hashlib.sha256(fixture_host.read_bytes()).hexdigest() if 'bookmark' in args.targets else None,
        swiftCLISHA256=hashlib.sha256(args.cli.read_bytes()).hexdigest() if args.cli else None,
        cliBridgeSHA256=hashlib.sha256((args.cli.parent / 'thumble-cli-bridge').read_bytes()).hexdigest() if args.cli else None,
        hostSHA256=hashlib.sha256(Path(host).read_bytes()).hexdigest(),
        testAPKSHA256=hashlib.sha256((root / 'app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk').read_bytes()).hexdigest())
    destination = root / 'app/build/evidence/profile-actions/rust-application-launch-result.json'
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(evidence, indent=2) + '\n')
    print(json.dumps(evidence, indent=2))
