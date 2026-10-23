"""Explicit-map native iOS runtime diagnostic; does not replace bundled React QA.

Run inside run_mobile_app_probe.py --platform ios -- python3 this-file --report ... .
Only fixed outcomes leave the owned simulator; all production TLS deadlines remain intact.
"""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
BUNDLE = 'com.codybontecou.thumble.rewrite.tls-runtime-probe'
PHASES = {'launch', 'begin', 'admission', 'fresh', 'renewal-start', 'holding', 'renewal-verified', 'held', 'neutral', 'finish', 'runner-preparing', 'runner-compiling', 'runner-signing', 'runner-runtime', 'runner-creating', 'runner-booting', 'runner-installing', 'runner-launching', 'runner-waiting'}
RUNTIME = {'idle', 'ready', 'closed', 'cancelled', 'read-deadline', 'write-deadline', 'read-failed', 'write-failed', 'invalid-frame', 'queue-overflow', 'network-failed'}
CONTROL = {'none', 'checkpoint', 'progress', 'renewal', 'status', 'offering'}


def validate_result(value):
    fields = {'version', 'scope', 'passed', 'phase', 'generation', 'elapsedMs', 'publications', 'maximumPublicationGapMs', 'tlsRuntimeOutcome', 'controlFailureStage'}
    if type(value) is not dict or set(value) != fields:
        raise ValueError('ios_runtime_result_invalid')
    if type(value['version']) is not int or value['version'] != 1 or value['scope'] != 'explicit-map-ios-runtime' or type(value['passed']) is not bool:
        raise ValueError('ios_runtime_result_invalid')
    if any(type(value[key]) is not str for key in ('phase', 'generation', 'tlsRuntimeOutcome', 'controlFailureStage')):
        raise ValueError('ios_runtime_result_invalid')
    if value['phase'] not in PHASES or value['generation'] not in {'1', '2'} or value['tlsRuntimeOutcome'] not in RUNTIME or value['controlFailureStage'] not in CONTROL:
        raise ValueError('ios_runtime_result_invalid')
    for key, maximum in [('elapsedMs', 180000), ('publications', 1000000), ('maximumPublicationGapMs', 180000)]:
        if type(value[key]) is not int or not 0 <= value[key] <= maximum:
            raise ValueError('ios_runtime_result_invalid')
    if value['passed'] and (value['phase'] != 'finish' or value['generation'] != '2'):
        raise ValueError('ios_runtime_result_invalid')
    return value


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def runtime_sources():
    # Pure native dependencies of PhoneConnection must also be linked into this
    # isolated host; no Expo module, React view or product app is compiled here.
    return tuple(ROOT / path for path in (
        'tooling/ios-tls-runtime/Probe.swift',
        'apps/mobile/modules/thumble-input/ios/PhoneConnection.swift',
        'apps/mobile/modules/thumble-input/ios/PairingQRScanner.swift',
    ))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    config = json.loads((ROOT / 'apps/mobile/tests/ios/AppProbeConfig.json').read_text())
    assert type(config) is dict and set(config) == {'port'} and type(config['port']) is int and 0 < config['port'] < 65536, 'ios_runtime_config_invalid'
    device = None
    runner_phase = 'runner-preparing'
    reported = False
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.unlink(missing_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix='thumble-ios-tls-runtime-') as temporary:
            folder = Path(temporary)
            app = folder / 'TLSRuntimeProbe.app'
            app.mkdir()
            metadata = {'CFBundleIdentifier': BUNDLE, 'CFBundleExecutable': 'TLSRuntimeProbe', 'CFBundleName': 'TLSRuntimeProbe', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0', 'MinimumOSVersion': '17.0', 'LSRequiresIPhoneOS': True, 'UIDeviceFamily': [1], 'UILaunchScreen': {}, 'NSLocalNetworkUsageDescription': 'Connect to an owned recording-only test receiver.', 'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True}}
            (app / 'Info.plist').write_bytes(plistlib.dumps(metadata))
            # Simulator-only entitlement section, matching the entitled real app QA host.
            entitlements = plistlib.loads((ROOT / 'apps/mobile/tests/ios/Simulator.entitlements').read_bytes())
            entitlements['application-identifier'] = 'THUMBLECI1.' + BUNDLE
            entitlements['keychain-access-groups'] = ['THUMBLECI1.' + BUNDLE]
            entitlement_path = folder / 'Simulator.entitlements'
            entitlement_path.write_bytes(plistlib.dumps(entitlements))
            runner_phase = 'runner-compiling'
            sdk = command('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path')
            libraries = ROOT / 'reports/mobile-ios-iphonesimulator'
            subprocess.run(['xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-swift-version', '6', '-parse-as-library', '-sdk', sdk, '-target', 'arm64-apple-ios17.0-simulator', '-I', str(libraries), '-L', str(libraries), '-lMobileInputUIKit', '-lMobileInputCore', '-lThumbleContracts', '-Xlinker', '-sectcreate', '-Xlinker', '__TEXT', '-Xlinker', '__entitlements', '-Xlinker', str(entitlement_path), *[str(source) for source in runtime_sources()], '-o', str(app / 'TLSRuntimeProbe')], check=True)
            (app / 'controller-layout-v1.json').write_bytes((ROOT / 'packages/fixtures/controller-layout-v1.json').read_bytes())
            runner_phase = 'runner-signing'
            subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, stdout=subprocess.DEVNULL)
            subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
            runner_phase = 'runner-runtime'
            available = json.loads(command('xcrun', 'simctl', 'list', 'runtimes', 'available', '-j'))['runtimes']
            runtime = max((r for r in available if r.get('isAvailable') and '.iOS-' in r['identifier']), key=lambda r: tuple(map(int, r['version'].split('.'))))
            runner_phase = 'runner-creating'
            device = command('xcrun', 'simctl', 'create', 'Thumble TLS Runtime Probe', 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro', runtime['identifier'])
            runner_phase = 'runner-booting'
            subprocess.run(['xcrun', 'simctl', 'boot', device], check=True)
            subprocess.run(['xcrun', 'simctl', 'bootstatus', device, '-b'], check=True, stdout=subprocess.DEVNULL)
            runner_phase = 'runner-installing'
            subprocess.run(['xcrun', 'simctl', 'install', device, str(app)], check=True)
            container = Path(command('xcrun', 'simctl', 'get_app_container', device, BUNDLE, 'data'))
            result_file = container / 'Documents/result.json'
            runner_phase = 'runner-launching'
            subprocess.run(['xcrun', 'simctl', 'launch', device, BUNDLE, str(config['port'])], check=True, stdout=subprocess.DEVNULL)
            runner_phase = 'runner-waiting'
            until = time.monotonic() + 180
            while not result_file.exists() and time.monotonic() < until:
                time.sleep(.1)
            if not result_file.is_file() or result_file.stat().st_size > 2048:
                raise RuntimeError('ios_runtime_result_missing')
            result = validate_result(json.loads(result_file.read_text()))
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps(result, sort_keys=True) + '\n')
            reported = True
            print(json.dumps(result, sort_keys=True), flush=True)
            assert result['passed'], 'ios_runtime_witness_failed'
    except Exception:
        if not reported:
            failure = validate_result(dict(version=1, scope='explicit-map-ios-runtime', passed=False, phase=runner_phase, generation='1', elapsedMs=0, publications=0, maximumPublicationGapMs=0, tlsRuntimeOutcome='idle', controlFailureStage='none'))
            args.report.write_text(json.dumps(failure, sort_keys=True) + '\n')
        raise
    finally:
        if device is not None:
            subprocess.run(['xcrun', 'simctl', 'shutdown', device], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(['xcrun', 'simctl', 'delete', device], check=True)


if __name__ == '__main__':
    main()
