#!/usr/bin/env python3
"""Real Mac receiver / physical Android skin acceptance using private host state.

Archives are existing unchanged packages. No design approval/publication occurs.
Pairing credentials stay in memory; normal receiver state is never selected.
"""
import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
from urllib.parse import urlsplit
import zipfile

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--serial',required=True)
p.add_argument('--adb',default='adb')
p.add_argument('--host',type=Path,required=True)
p.add_argument('--cli',type=Path,required=True)
p.add_argument('--bridge',type=Path,required=True)
p.add_argument('--cli-bridge',type=Path,required=True)
a=p.parse_args()
root=Path(__file__).resolve().parents[2]
evidence=root/'Android/app/build/evidence/mac-skin-sync'/time.strftime('%Y%m%d-%H%M%S')
evidence.mkdir(parents=True,exist_ok=False)
base=[a.adb,'-s',a.serial]
assert not a.serial.startswith('emulator-'),'Physical Android phone required'
first=root/'Host/fixtures/legacy-skin-packages/solar-sumi-1.0.0-edbecde5b708.pocketpad'
second=root/'Host/fixtures/legacy-skin-packages/foldline-relay-1.0.0-d04c121e9b0a.pocketpad'
def reference(path):
    with zipfile.ZipFile(path) as z:v=json.loads(z.read('manifest.json'))
    return v['identifier']+'@'+v['version']
def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def adb(*args,**kw):return subprocess.run(base+list(args),check=True,capture_output=True,**kw)
def phase():
    r=subprocess.run(base+['shell','cat','/sdcard/Android/data/com.thumble.android/files/mac-skin-sync/phase-history.txt'],capture_output=True,text=True)
    return r.stdout.strip() if r.returncode==0 else ''
with tempfile.TemporaryDirectory(prefix='thumble-skin-') as d:
    folder=Path(d);binary=folder/'bin';binary.mkdir()
    for src,name in [(a.host,'thumble-host'),(a.cli,'thumble'),(a.bridge,'thumble-bridge'),(a.cli_bridge,'thumble-cli-bridge')]:
        shutil.copy2(src,binary/name)
    state=folder/'state';state.mkdir(mode=0o700)
    env=dict(os.environ,THUMBLE_HOST_STATE_DIR=str(state),THUMBLE_HOST_CONTROL_SOCKET=str(folder/'control.sock'))
    fixture=json.loads((root/'Host/fixtures/controller-templates/v1/productivityStarter.json').read_text())['profile']
    fixture['name']='Mac skin sync acceptance';fixture['orientationPreference']='portrait'
    initial=dict(schemaVersion=3,serverID='mac-skin-sync-acceptance',trustedClients={},profiles=[fixture],activeProfileID=fixture['id'],defaultProfileID=fixture['id'])
    (state/'state.json').write_text(json.dumps(initial));(state/'state.json').chmod(0o600)
    def run(*args):
        r=subprocess.run([str(binary/'thumble-host'),*args],env=env,capture_output=True,text=True)
        if r.returncode:raise RuntimeError('Private receiver command failed: '+r.stderr[:500])
        return r.stdout
    def cli(*args,ok=True):
        r=subprocess.run([str(binary/'thumble'),*args],env=env,capture_output=True,text=True)
        if ok and r.returncode:raise RuntimeError('Staged Swift CLI failed: '+r.stderr[:700])
        if not ok:assert r.returncode!=0,'Invalid command unexpectedly succeeded'
        return r.stdout
    def status():
        value=json.loads(run('status','--json'));return value.get('status',value)
    def wait_phase(expected,process):
        deadline=time.monotonic()+80
        while expected not in phase().splitlines():
            if process.poll() is not None:raise RuntimeError('Instrumentation exited before '+expected)
            if time.monotonic()>deadline:raise RuntimeError('Timed out waiting for '+expected+'; last phase '+phase())
            time.sleep(.15)
    started=False;process=None
    try:
        run('start','--port','0','--no-input','--no-bonjour');started=True
        print('Private receiver running; importing and applying through the Swift CLI',flush=True)
        cli('skin','import',str(first),'--replace')
        cli('skin','apply',reference(first),'--profile','active')
        exported=folder/'exact.pocketpad';cli('skin','export',reference(first),'-o',str(exported));assert exported.read_bytes()==first.read_bytes()
        before=json.loads((state/'state.json').read_text())
        # Failure must leave both authority and installed archive intact.
        invalid=folder/'bad.pocketpad';invalid.write_bytes(b'not a skin archive')
        cli('skin','import',str(invalid),'--replace',ok=False)
        assert json.loads((state/'state.json').read_text())==before
        cli('skin','remove',reference(first),ok=False)
        for path in ['Android/app/build/outputs/apk/debug/app-debug.apk','Android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk']:
            adb('install','-r',str(root/path))
        adb('shell','rm','-rf','/sdcard/Android/data/com.thumble.android/files/mac-skin-sync')
        current=status()
        urls=[u for u in current['urls'] if (lambda v:v.version==4 and v.is_private and not v.is_loopback and not v.is_link_local)(ipaddress.ip_address(urlsplit(u).hostname))]
        assert urls,'No private LAN endpoint reachable by physical Android'
        qr=json.dumps(dict(type='pocketpad-pair',urls=urls,pairingCode=current['pairingCode'],serverID=current['serverID']))
        with (evidence/'instrumentation.log').open('w') as log:
            process=subprocess.Popen(base+['shell','am','instrument','-w','-r','-e','class','com.thumble.android.MacSkinSyncDeviceTest',
                '-e','macSkinPairingQR',"'"+qr.replace("'","'\\''")+"'",'com.thumble.android.test/androidx.test.runner.AndroidJUnitRunner'],stdout=log,stderr=log)
            wait_phase('detached',process)
            detached=json.loads((state/'state.json').read_text());assert not detached['profiles'][0].get('skinReference')
            print('Physical phone detach durably acknowledged by Mac',flush=True)
            wait_phase('applied',process)
            deadline=time.monotonic()+5
            while not (status()['core']['pressedButtons'] or status()['core']['pressedElements']):
                assert time.monotonic()<deadline,'Held physical capture did not reach receiver'
                time.sleep(.05)
            applied=json.loads((state/'state.json').read_text());assert applied['profiles'][0]['skinReference']['identifier']==reference(second).split('@')[0]
            cli('skin','export',reference(second),'-o',str(exported));assert exported.read_bytes()==second.read_bytes()
            print('Physical phone archive upload and native apply durably acknowledged',flush=True)
            cli('skin','apply',reference(first),'--profile','active')
            wait_phase('cli-applied',process);wait_phase('disconnected',process)
            assert not status()['core']['pressedButtons'] and not status()['core']['pressedElements']
            run('stop');started=False
            run('start','--port',str(current['port']),'--no-input','--no-bonjour');started=True
            adb('shell','touch','/sdcard/Android/data/com.thumble.android/files/mac-skin-sync/continue.txt')
            wait_phase('done',process);process.wait(timeout=15)
        assert process.returncode==0 and 'OK (1 test)' in (evidence/'instrumentation.log').read_text()
        final=status();assert not final['core']['paired'];assert not final['output']['heldKeyCount'] and not final['output']['heldPointerButtons']
        adb('pull','/sdcard/Android/data/com.thumble.android/files/mac-skin-sync',str(evidence/'device'))
        result=json.loads((evidence/'device/result.json').read_text());assert result['physicalDevice']
        result.update(nativeSwiftCLIExportExact=True,invalidImportPreservesState=True,inUseRemovalRejected=True,normalMacReceiverTouched=False,
            hostBinarySHA256=sha(binary/'thumble-host'),swiftBridgeSHA256=sha(binary/'thumble-bridge'),swiftCLISHA256=sha(binary/'thumble'))
        (evidence/'acceptance.json').write_text(json.dumps(result,indent=2)+'\n')
        print(json.dumps(result,indent=2));print('Evidence: '+str(evidence))
    finally:
        if process is not None and process.poll() is None:
            # Let the bounded test fail and run its restoration finally block.
            try:process.wait(timeout=40)
            except subprocess.TimeoutExpired:process.terminate();process.wait(timeout=5)
        if started:run('stop')
        if (state/'host.log').exists():shutil.copy2(state/'host.log',evidence/'private-host.log')
