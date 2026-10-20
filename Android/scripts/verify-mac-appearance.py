#!/usr/bin/env python3
"""Verify Android appearance sync against a private Rust Mac receiver.

Uses memory-only Android session state and a no-input, no-Bonjour receiver.
Pairing data remains in memory and never enters the receipt or command output.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from urllib.parse import urlsplit
import uuid

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--serial',required=True)
parser.add_argument('--adb',default='adb')
parser.add_argument('--host',type=Path,required=True)
parser.add_argument('--bridge',type=Path,required=True)
a=parser.parse_args()
root=Path(__file__).resolve().parents[2]
evidence=root/'Android/app/build/evidence/appearance-preference'/datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
evidence.mkdir(parents=True,exist_ok=False)
base=[a.adb,'-s',a.serial]

def adb(*args):
    result=subprocess.run(base+list(args),capture_output=True,text=True)
    if result.returncode:raise RuntimeError('Device setup failed; pairing arguments withheld')
    return result.stdout

with tempfile.TemporaryDirectory(prefix='thumble-appearance-') as d:
    folder=Path(d);binary=folder/'bin';binary.mkdir(mode=0o700)
    executable=binary/'thumble-host';shutil.copy2(a.host,executable)
    shutil.copy2(a.bridge,binary/'thumble-bridge')
    state=folder/'state';state.mkdir(mode=0o700)
    env=dict(os.environ,THUMBLE_HOST_STATE_DIR=str(state),THUMBLE_HOST_CONTROL_SOCKET=str(folder/'control.sock'))
    profile=json.loads((root/'Host/fixtures/controller-templates/v1/productivityStarter.json').read_text())['profile']
    profile['customization']['colorSchemePreference']='system'
    inactive=json.loads((root/'Host/fixtures/controller-templates/v1/gameBoy.json').read_text())['profile']
    inactive['id']='4FD20F4A-3C83-40B5-87C0-64512F4AC925'
    inactive['customization']['colorSchemePreference']='system'
    initial=dict(schemaVersion=3,configurationRevision=1,serverID='appearance-acceptance-'+str(uuid.uuid4()),trustedClients={},
        profiles=[profile,inactive],activeProfileID=profile['id'],defaultProfileID=profile['id'])
    saved=state/'state.json';saved.write_text(json.dumps(initial));saved.chmod(0o600)
    def host(*args):
        result=subprocess.run([str(executable),*args],env=env,capture_output=True,text=True)
        if result.returncode:raise RuntimeError('Private receiver command failed')
        return result.stdout
    started=False
    try:
        host('start','--port','0','--no-input','--no-bonjour');started=True
        status=json.loads(host('status','--json'));status=status.get('status',status)
        assert status['inputEnabled'] is False
        if a.serial.startswith('emulator-'):
            urls=[f"ws://10.0.2.2:{status['port']}"]
        else:
            urls=[u for u in status['urls'] if (lambda v:v.version==4 and v.is_private and not v.is_loopback and not v.is_link_local)(ipaddress.ip_address(urlsplit(u).hostname))]
        assert urls,'No device-reachable private receiver endpoint'
        qr=json.dumps(dict(type='pocketpad-pair',urls=urls,pairingCode=status['pairingCode'],serverID=status['serverID']))
        adb('install','-r',str(root/'Android/app/build/outputs/apk/debug/app-debug.apk'))
        adb('install','-r',str(root/'Android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk'))
        with (evidence/'instrumentation.log').open('w') as log:
            try:
                result=subprocess.run(base+['shell','am','instrument','-w','-e','class',
                'com.thumble.android.AppearancePreferenceDeviceTest#realRustReceiverPersistsAndAcknowledgesBothAppearanceChoices',
                '-e','appearancePairingQR',"'"+qr.replace("'","'\\''")+"'",'com.thumble.android.test/androidx.test.runner.AndroidJUnitRunner'],stdout=log,stderr=log,timeout=90)
            except subprocess.TimeoutExpired:
                adb('shell','am','force-stop','com.thumble.android')
                raise RuntimeError('Real receiver instrumentation timed out; pairing arguments withheld') from None
        report=(evidence/'instrumentation.log').read_text()
        assert result.returncode==0 and 'OK (1 test)' in report,'Real receiver acceptance failed; see instrumentation log'
        final=json.loads(saved.read_text())
        assert final['profiles'][0]['id']==profile['id']
        assert final['profiles'][0]['customization']['colorSchemePreference']=='light'
        assert final['profiles'][1]['id']==inactive['id']
        assert final['profiles'][1]['customization']['colorSchemePreference']=='dark'
        assert final['activeProfileID']==profile['id'] and final['defaultProfileID']==profile['id']
        assert final['configurationRevision']>=4
        current=json.loads(host('status','--json'));current=current.get('status',current)
        assert current['inputEnabled'] is False
        assert current['output']['heldKeyCount']==0
        receipt=dict(passed=True,serialKind='emulator' if a.serial.startswith('emulator-') else 'physical',
            inputEnabled=False,heldKeys=0,configurationRevision=final['configurationRevision'],
            finalAppearance='light',inactiveAppearance='dark',inactiveProfileSyncedWithoutSelection=True,profileIdentityPreserved=True,
            hostSHA256=hashlib.sha256(a.host.read_bytes()).hexdigest(),
            bridgeSHA256=hashlib.sha256(a.bridge.read_bytes()).hexdigest(),
            androidSession='memory-only',normalMacInstallationChanged=False)
        (evidence/'acceptance.json').write_text(json.dumps(receipt,indent=2)+'\n')
        print(json.dumps(dict(passed=True,evidence=str(evidence),configurationRevision=final['configurationRevision'])))
    finally:
        if started:host('stop')
