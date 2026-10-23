"""Owned simulator actual-React bank witness; raw UI evidence stays private."""
import argparse
import json
import os
from pathlib import Path
import queue
import re
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parent.parent
OWNED = '2C25402F-F87F-46EA-A615-A1A9C0689EC6'
CASE = 'testActualReactModifierBankArtworkAndAppearanceRefresh'


def validate_owned_simulator(identifier, inventory):
    assert type(identifier) is str and re.fullmatch(r'[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}', identifier)
    assert type(inventory) is dict and type(inventory.get('devices')) is dict
    devices = inventory['devices']
    assert len(devices) <= 128
    matches = []
    count = 0
    for group in devices.values():
        assert type(group) is list
        count += len(group)
        assert count <= 2048
        for device in group:
            assert type(device) is dict
            if device.get('udid') == identifier:
                matches.append(device)
    assert len(matches) == 1 and matches[0].get('isAvailable') is True
    name = matches[0].get('name')
    assert identifier == OWNED or (type(name) is str and re.fullmatch(r'Thumble Rewrite Bank CI [A-Za-z0-9_-]{1,64}', name))


def cleanup_all(actions):
    succeeded = True
    for action in actions:
        try:
            action()
        except BaseException:
            succeeded = False
    return succeeded


def verify_results(summary, tree):
    assert type(summary) is dict and type(tree) is dict
    assert all(type(summary[key]) is int for key in ('totalTestCount', 'passedTests', 'failedTests', 'skippedTests'))
    assert summary['totalTestCount'] == 1 and summary['passedTests'] == 1
    assert summary['failedTests'] == 0 and summary['skippedTests'] == 0
    assert summary['result'] == 'Passed'
    pending = list(tree['testNodes'])
    cases = []
    count = 0
    while pending:
        count += 1
        assert count <= 256
        node = pending.pop()
        assert type(node) is dict
        if node['nodeType'] == 'Test Case':
            cases.append(node)
        pending.extend(node.get('children', []))
    assert len(cases) == 1
    assert cases[0]['name'].removesuffix('()') == CASE
    assert cases[0]['nodeIdentifier'].removesuffix('()') == 'BankPresentationUITests/' + CASE
    assert cases[0]['result'] == 'Passed'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--device', default=OWNED)
    parser.add_argument('--derived-data', required=True)
    parser.add_argument('--service-probe', type=Path, default=ROOT / 'tooling/presentation-service-probe.ts')
    args = parser.parse_args()
    inventory_data = subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '--json'], timeout=15)
    assert len(inventory_data) <= 2097152
    validate_owned_simulator(args.device, json.loads(inventory_data))
    assert args.service_probe.is_absolute() and args.service_probe.is_file()
    assert args.service_probe.name == 'presentation-service-probe.ts'
    private = Path(os.environ['RUNNER_TEMP'])
    private.mkdir(parents=True, exist_ok=True, mode=0o700)
    result = private / 'bank-presentation-ios.xcresult'
    assert not result.exists(), 'select_fresh_private_result_directory'
    process = None
    lines = queue.Queue(maxsize=32)
    lock = threading.Lock()
    phases = []
    complete = False
    capture_timings = []
    appearance = subprocess.check_output(
        ['xcrun', 'simctl', 'ui', args.device, 'appearance'], text=True).strip().lower()
    assert appearance in ('light', 'dark')
    config = ROOT / 'apps/mobile/tests/ios/SavedControllerAppProbeConfig.json'
    previous = config.read_bytes() if config.exists() else None

    def command(byte):
        assert process is not None and process.poll() is None
        process.stdin.write(byte.encode('ascii'))
        process.stdin.flush()
        data = lines.get(timeout=6)
        assert 0 < len(data) <= 16384
        value = json.loads(data)
        assert type(value) is dict
        return value

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            nonlocal process, complete
            try:
                with lock:
                    assert self.path in ('/begin', '/capture', '/dark', '/bank-hold-start', '/refresh', '/bank-held', '/neutral', '/finish')
                    if self.path == '/capture':
                        capture = private / 'bank-ios-visible-last.png'
                        before = command('i')
                        started = time.monotonic()
                        subprocess.run(['xcrun', 'simctl', 'io', args.device, 'screenshot', str(capture)],
                                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
                        elapsed = int((time.monotonic() - started) * 1000)
                        after = command('i')
                        assert type(before['active']) is bool and type(after['active']) is bool
                        reason = after['reason']
                        assert type(reason) is str and 0 < len(reason) <= 80
                        assert all(c.isascii() and (c.isalnum() or c == '_') for c in reason)
                        assert len(capture_timings) < 128
                        capture_timings.append({'elapsedMs': min(elapsed, 10000), 'activeBefore': before['active'],
                                                'activeAfter': after['active'], 'reasonAfter': reason})
                        (private / 'bank-capture-timings.json').write_text(json.dumps(capture_timings) + '\n')
                        assert 8 < capture.stat().st_size <= 2097152
                        payload = capture.read_bytes()
                        assert payload.startswith(b'\x89PNG\r\n\x1a\n')
                        self.send_response(200)
                        self.send_header('Content-Length', str(len(payload)))
                        self.end_headers()
                        self.wfile.write(payload)
                        return
                    if self.path == '/begin':
                        assert process is None
                        stderr = (private / 'bank-service-private.log').open('wb')
                        process = subprocess.Popen(
                            [str(ROOT / 'tooling/ios-bank-presentation-service-probe.ts'), '--service-probe', str(args.service_probe), '--bank-presentation'],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr)
                        def read():
                            for line in process.stdout:
                                if len(line) > 16384:
                                    break
                                lines.put(line)
                            lines.put(b'')
                        threading.Thread(target=read, daemon=True).start()
                        offer = json.loads(lines.get(timeout=15))
                        assert offer['scope'] == 'synthetic-loopback-recording-only'
                        assert command('a')['active'] is True
                        value = {'host': '127.0.0.1', 'port': offer['port'], 'certificatePin': offer['pin'],
                                 'authorityInstanceId': offer['authorityInstanceId'], 'windowId': offer['windowId'],
                                 'secret': offer['secret'], 'expiresAt': offer['expiresAt']}
                    elif self.path == '/dark':
                        subprocess.run(['xcrun', 'simctl', 'ui', args.device, 'appearance', 'dark'], check=True,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
                        value = {'dark': True}
                        phases.append(self.path)
                    else:
                        value = command({'/bank-hold-start': 'w', '/refresh': 'm', '/bank-held': 'g', '/neutral': 'n', '/finish': 'f'}[self.path])
                        if self.path == '/bank-held':
                            assert value['bankHeld'] is True and value['neutralPulses'] == 0
                            assert value['inputTtlMs'] == 350 and value['inputEnabled'] is False
                        if self.path == '/finish':
                            assert process.wait(timeout=6) == 0
                            complete = True
                        phases.append(self.path)
                    payload = json.dumps(value, separators=(',', ':')).encode()
                    self.send_response(200)
            except Exception:
                payload = b'{"error":"bank_ios_probe_failed"}'
                self.send_response(500)
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_POST(self):
            try:
                assert self.path == '/screenshot'
                length = int(self.headers.get('Content-Length', '0'))
                assert 8 < length <= 2097152
                image = self.rfile.read(length)
                assert len(image) == length and image.startswith(b'\x89PNG\r\n\x1a\n')
                (private / 'bank-ios-xctest-private.png').write_bytes(image)
                capture = private / 'bank-presentation-ios-dark-both.png'
                subprocess.run(['xcrun', 'simctl', 'io', args.device, 'screenshot', str(capture)],
                               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
                assert 8 < capture.stat().st_size <= 2097152
                assert capture.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
                self.send_response(200)
            except Exception:
                self.send_response(400)
            self.end_headers()

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server_started = False
    config_changed = False
    passed = False
    primary = None
    try:
        threading.Thread(target=server.serve_forever, daemon=True).start()
        server_started = True
        config.write_text(json.dumps({'port': server.server_port, 'mode': 'bank-presentation'}))
        config_changed = True
        subprocess.run(['xcrun', 'simctl', 'ui', args.device, 'appearance', 'light'], check=True)
        subprocess.run(['ruby', 'apps/mobile/tests/prepare-ios-bank.rb'], cwd=ROOT, check=True,
                       stdout=subprocess.DEVNULL)
        arguments = ['xcodebuild', '-quiet', '-workspace', 'apps/mobile/ios/ThumbleRewrite.xcworkspace',
                     '-scheme', 'BankPresentationUITests', '-configuration', 'Release',
                     '-destination', f'platform=iOS Simulator,id={args.device}', '-derivedDataPath', args.derived_data,
                     '-resultBundlePath', str(result), '-parallel-testing-enabled', 'NO', '-test-timeouts-enabled', 'YES',
                     '-default-test-execution-time-allowance', '180', '-maximum-test-execution-time-allowance', '240',
                     '-collect-test-diagnostics', 'never', 'ONLY_ACTIVE_ARCH=YES', 'ENABLE_TESTABILITY=YES',
                     '-only-testing:BankPresentationUITests/BankPresentationUITests', 'test']
        with (private / 'bank-ios-ui-private.log').open('wb') as log:
            status = subprocess.call(arguments, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=900)
        if status != 0 and process is not None and process.poll() is None:
            try:
                diagnostic = command('i')
                keys = {'active', 'generation', 'revision', 'reason', 'firstReason', 'firstGeneration', 'firstRevision'}
                assert set(diagnostic) == keys and type(diagnostic['active']) is bool
                for key in keys - {'active'}:
                    value = diagnostic[key]
                    assert type(value) is str and 0 < len(value) <= 80
                    assert all(c.isascii() and (c.isalnum() or c in '_-') for c in value)
                (private / 'bank-input-failure.json').write_text(json.dumps(diagnostic, sort_keys=True) + '\n')
            except Exception:
                (private / 'bank-input-failure.json').write_text('{"reason":"diagnostic_unavailable"}\n')
        summary = {}
        tree = {}
        for name in ('summary', 'tests'):
            data = subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', name,
                                           '--schema-version', '0.1.0', '--path', str(result)], timeout=15)
            assert len(data) <= 2097152
            parsed = json.loads(data)
            if name == 'summary':
                summary = parsed
            else:
                tree = parsed
        verify_results(summary, tree)
        assert status == 0 and complete
        assert phases == ['/dark', '/bank-hold-start', '/refresh', '/bank-held', '/neutral', '/finish']
        assert (private / 'bank-presentation-ios-dark-both.png').is_file()
        passed = True
    except BaseException as error:
        primary = error
    finally:
        def close_native():
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        def restore_config():
            if config_changed:
                if previous is None:
                    config.unlink(missing_ok=True)
                else:
                    config.write_bytes(previous)
        clean = cleanup_all([
            lambda: server.shutdown() if server_started else None,
            server.server_close,
            close_native,
            lambda: subprocess.run(['xcrun', 'simctl', 'ui', args.device, 'appearance', appearance],
                                   check=True, stdout=subprocess.DEVNULL, timeout=10),
            restore_config,
        ])
        passed = passed and clean
        report = {'scope': 'actual-react-ios-bank-artwork', 'status': 'passed' if passed else 'failed'}
        if passed:
            report.update(cases=1, failures=0, skipped=0, banks=4, themes=2, heldAcrossRefresh=True)
        if not clean:
            report['cleanupFailed'] = True
        try:
            (private / 'bank-ios-sanitized.json').write_text(json.dumps(report, sort_keys=True) + '\n')
        except BaseException:
            passed = False
            report = {'scope': 'actual-react-ios-bank-artwork', 'status': 'failed', 'reportWriteFailed': True}
        print(json.dumps(report, sort_keys=True))
    if primary is not None:
        raise primary
    if not passed:
        raise SystemExit('bank_ios_app_witness_failed')


if __name__ == '__main__':
    main()
