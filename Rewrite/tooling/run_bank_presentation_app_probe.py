"""Private synthetic presentation peer for the actual bundled recording app.

No invitation, raw child output, image bytes or credentials enter stdout reports.
"""
import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
import xml.etree.ElementTree as ET
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parent.parent


def verify_android_results(directory):
    files=list(Path(directory).rglob('TEST-*.xml'))
    assert len(files)==1
    source=files[0]
    assert 0 < source.stat().st_size <= 2097152
    root=ET.fromstring(source.read_bytes())
    assert root.tag in {'testsuite','testsuites'}
    if root.tag=='testsuites':
        assert len(root)==1 and root[0].tag=='testsuite'
        suite=root[0]
    else:
        suite=root
    assert len(list(root.iter('testsuite')))==1 and len(suite.findall('testcase'))==1
    for summary in [root,suite]:
        assert summary.get('tests')=='1'
        assert all(summary.get(key)=='0' for key in ('failures','errors','skipped'))
    cases=list(root.iter('testcase'))
    assert len(cases)==1
    case=cases[0]
    assert case.get('classname')=='com.thumble.rewrite.qa.BankPresentationAppTest'
    assert case.get('name')=='actualModifierBanksTrackNativeHeldStateAndRefresh'
    assert all(case.find(tag) is None for tag in ('failure','error','skipped'))
    for suite in root.iter('testsuite'):
        assert int(suite.attrib['tests'])==1
        assert all(int(suite.get(key,'0'))==0 for key in ('failures','errors','skipped'))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--platform', choices=['android'], required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    serial = os.environ['ANDROID_SERIAL']
    assert serial == 'emulator-5580', 'select_owned_presentation_emulator'
    adb = str(Path(os.environ['ANDROID_HOME']) / 'platform-tools/adb')
    private = Path(os.environ['RUNNER_TEMP']); private.mkdir(parents=True, exist_ok=True, mode=0o700)
    lines = queue.Queue(maxsize=32)
    process = None
    lock = threading.Lock()
    complete = False
    phases = []
    ports = set()

    def reverse(port):
        subprocess.run([adb,'-s',serial,'reverse',f'tcp:{port}',f'tcp:{port}'],check=True,stdout=subprocess.DEVNULL)
        ports.add(port)

    def command(byte):
        assert process is not None and process.poll() is None
        process.stdin.write(byte.encode('ascii'));process.stdin.flush()
        data = lines.get(timeout=6)
        assert 0 < len(data) <= 16384
        value=json.loads(data)
        assert type(value) is dict
        return value

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            nonlocal process, complete
            try:
                with lock:
                    assert self.path in {'/begin','/bank-hold-start','/refresh','/bank-held','/neutral','/finish'}
                    if self.path == '/begin':
                        assert process is None
                        stderr=(private/'presentation-native-private.log').open('wb')
                        process=subprocess.Popen([str(ROOT/'tooling/presentation-service-probe.ts'),'--bank-presentation'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=stderr)
                        def read():
                            for line in process.stdout:
                                if len(line)>16384: break
                                lines.put(line)
                            lines.put(b'')
                        threading.Thread(target=read,daemon=True).start()
                        offer=json.loads(lines.get(timeout=15))
                        assert offer['scope']=='synthetic-loopback-recording-only'
                        assert command('a')['active'] is True
                        reverse(offer['port'])
                        value={'host':'127.0.0.1','port':offer['port'],'certificatePin':offer['pin'],'authorityInstanceId':offer['authorityInstanceId'],'windowId':offer['windowId'],'secret':offer['secret'],'expiresAt':offer['expiresAt']}
                    else:
                        value=command({'/bank-hold-start':'w','/refresh':'m','/bank-held':'g','/neutral':'n','/finish':'f'}[self.path])
                        if self.path=='/bank-held':
                            assert value['bankHeld'] is True and value['neutralPulses']==0 and value['inputTtlMs']==350 and value['inputEnabled'] is False
                        if self.path=='/finish':
                            assert process.wait(timeout=6)==0
                            complete=True
                        phases.append(self.path)
                    payload=json.dumps(value,separators=(',',':')).encode()
                    self.send_response(200)
            except Exception:
                payload=b'{"error":"presentation_app_probe_failed"}'
                self.send_response(500)
            self.send_header('Content-Length',str(len(payload)));self.end_headers();self.wfile.write(payload)
        def do_POST(self):
            try:
                assert self.path=='/screenshot'
                length=int(self.headers.get('Content-Length','0'))
                assert 8 < length <= 2097152
                image=self.rfile.read(length)
                assert len(image)==length and image.startswith(b'\x89PNG\r\n\x1a\n')
                (private/'bank-presentation-refreshed.png').write_bytes(image)
                self.send_response(200);self.end_headers()
            except Exception:
                self.send_response(400);self.end_headers()
        def log_message(self,*_): pass
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    reverse(server.server_port)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    command_args=args.command[1:] if args.command[:1]==['--'] else args.command
    command_args.append(f'-Pandroid.testInstrumentationRunnerArguments.thumbleProbePort={server.server_port}')
    try:
        with (private/'presentation-app-private.log').open('wb') as log:
            status=subprocess.call(command_args,stdout=log,stderr=subprocess.STDOUT,timeout=240)
        if status != 0 and process is not None and process.poll() is None:
            try:
                diagnostic=command('i')
                allowed={'active','generation','revision','reason','firstReason','firstGeneration','firstRevision'}
                assert set(diagnostic)==allowed and type(diagnostic['active']) is bool
                for key in allowed-{'active'}:
                    assert type(diagnostic[key]) is str and 0 < len(diagnostic[key]) <= 80
                    assert all(c.isascii() and (c.isalnum() or c in '_-') for c in diagnostic[key])
                (private/'bank-input-failure.json').write_text(json.dumps(diagnostic,sort_keys=True)+'\n')
            except Exception:
                (private/'bank-input-failure.json').write_text('{"scope":"bank-input-failure","reason":"diagnostic_unavailable"}\n')
        assert status==0 and complete
        verify_android_results(ROOT/'apps/mobile/android/app/build/outputs/androidTest-results/connected/nativeQa')
        assert (private/'bank-presentation-refreshed.png').is_file()
        assert phases==['/bank-hold-start','/refresh','/bank-held','/neutral','/finish']
        print(json.dumps({'scope':'actual-react-bank-presentation','status':'passed','heldAcrossRefresh':True,'phases':len(phases),'cases':1,'skipped':0,'failures':0}))
    finally:
        server.shutdown();server.server_close()
        if process is not None and process.poll() is None:
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill();process.wait(timeout=5)
        for port in ports: subprocess.run([adb,'-s',serial,'reverse','--remove',f'tcp:{port}'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)


if __name__=='__main__': main()
