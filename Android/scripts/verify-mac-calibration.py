#!/usr/bin/env python3
"""Accept an Android calibration repair on an isolated no-input native Mac receiver."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--serial',required=True)
parser.add_argument('--adb',default='adb')
parser.add_argument('--host',type=Path,required=True)
parser.add_argument('--bridge',type=Path,required=True)
a=parser.parse_args()
assert a.serial.startswith('emulator-'),'This fixture requires a dedicated emulator'
root=Path(__file__).resolve().parents[2]
evidence=root/'Android/app/build/evidence/calibration-receiver'/datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
evidence.mkdir(parents=True)
base=[a.adb,'-s',a.serial]
def adb(*args):
    result=subprocess.run(base+list(args),capture_output=True,text=True)
    if result.returncode: raise RuntimeError('Android command failed; pairing arguments withheld')
    return result.stdout
for apk in ['app/build/outputs/apk/debug/app-debug.apk','app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk']:
    adb('install','-r',str(root/'Android'/apk))
with tempfile.TemporaryDirectory(prefix='thumble-calibration-') as temp:
    folder=Path(temp);binary=folder/'bin';binary.mkdir(mode=0o700)
    for source,name in [(a.host,'thumble-host'),(a.bridge,'thumble-bridge')]: shutil.copy2(source,binary/name)
    state=folder/'state';state.mkdir(mode=0o700)
    env=dict(os.environ,THUMBLE_HOST_STATE_DIR=str(state),THUMBLE_HOST_CONTROL_SOCKET=str(folder/'control.sock'))
    profile=json.loads((root/'Host/fixtures/controller-templates/v1/productivityStarter.json').read_text())['profile']
    profile['orientationPreference']='portrait'
    profile['customization']['colorSchemePreference']='system'
    inactive=json.loads((root/'Host/fixtures/controller-templates/v1/gameBoy.json').read_text())['profile']
    inactive['id']='4FD20F4A-3C83-40B5-87C0-64512F4AC925'
    initial=dict(schemaVersion=3,configurationRevision=1,serverID='calibration-'+str(uuid.uuid4()),trustedClients={},
        profiles=[profile,inactive],activeProfileID=profile['id'],defaultProfileID=profile['id'])
    saved=state/'state.json';saved.write_text(json.dumps(initial));saved.chmod(0o600)
    def host(*args):
        result=subprocess.run([str(binary/'thumble-host'),*args],env=env,capture_output=True,text=True)
        if result.returncode: raise RuntimeError('Private calibration receiver command failed')
        return result.stdout
    started=False
    try:
        host('start','--port','0','--no-input','--no-bonjour');started=True
        status=json.loads(host('status','--json'));status=status.get('status',status)
        assert status['inputEnabled'] is False
        assert a.serial.startswith('emulator-'),'This fixture uses the dedicated emulator loopback route'
        before=json.loads(saved.read_text())
        qr=json.dumps(dict(type='pocketpad-pair',urls=[f"ws://10.0.2.2:{status['port']}"],pairingCode=status['pairingCode'],serverID=status['serverID']))
        adb('shell','rm','-f','/sdcard/Android/data/com.thumble.android/files/thumb-calibration-native-profile.json')
        with (evidence/'instrumentation.log').open('w') as log:
            try:
                completed=subprocess.run(base+['shell','am','instrument','-w','-e','class',
                    'com.thumble.android.ThumbCalibrationDeviceTest#realMacAcceptsCalibrationRepairAndReplaysItAfterReconnect',
                    '-e','calibrationPairingQR',"'"+qr.replace("'","'\\''")+"'",
                    'com.thumble.android.test/androidx.test.runner.AndroidJUnitRunner'],stdout=log,stderr=log,timeout=150)
            except subprocess.TimeoutExpired:
                adb('shell','am','force-stop','com.thumble.android')
                raise RuntimeError('Calibration acceptance timed out; pairing arguments withheld') from None
        report=(evidence/'instrumentation.log').read_text()
        assert completed.returncode==0 and 'OK (1 test)' in report,'Native calibration acceptance failed; see instrumentation log'
        final=json.loads(saved.read_text());active=final['profiles'][0];baseline=before['profiles'][0]
        assert final['profiles'][1]==before['profiles'][1]
        assert final['activeProfileID']==profile['id'] and final['defaultProfileID']==profile['id']
        allowed={'customization','portraitCustomization','landscapeCustomization','updatedAt'}
        assert {k:v for k,v in active.items() if k not in allowed}=={k:v for k,v in baseline.items() if k not in allowed}
        assert active['portraitCustomization']!=baseline.get('portraitCustomization',baseline['customization'])
        assert final['configurationRevision']>before['configurationRevision']
        expected=evidence/'android-profile.json'
        adb('pull','/sdcard/Android/data/com.thumble.android/files/thumb-calibration-native-profile.json',str(expected))
        def presentation(value):
            return {k:v for k,v in value.items() if k!='updatedAt'}
        assert presentation(active['portraitCustomization'])==presentation(json.loads(expected.read_text())['portraitCustomization'])
        assert presentation(active['landscapeCustomization'])==presentation(baseline['landscapeCustomization'])
        assert presentation(active['customization'])==presentation(active['portraitCustomization'])
        current=json.loads(host('status','--json'));current=current.get('status',current)
        assert current['inputEnabled'] is False and current['output']['heldKeyCount']==0
        host('stop');started=False
        host('start','--port',str(status['port']),'--no-input','--no-bonjour');started=True
        restarted=json.loads(saved.read_text())
        assert restarted['profiles']==final['profiles'] and restarted['configurationRevision']==final['configurationRevision']
        for name in ['native-score','native-acknowledged','native-reconnected']:
            adb('pull',f'/sdcard/Android/data/com.thumble.android/files/thumb-calibration-{name}.png',str(evidence/(name+'.png')))
        receipt=dict(passed=True,normalMacInstallationChanged=False,inputEnabled=False,heldKeys=0,
            profileIdentityAndMetadataPreserved=True,inactiveProfileUnchanged=True,repairAcknowledged=True,
            trustedReconnectRetainsRepair=True,receiverRestartRetainsRepair=True,configurationRevision=final['configurationRevision'],
            hostSHA256=hashlib.sha256(a.host.read_bytes()).hexdigest(),bridgeSHA256=hashlib.sha256(a.bridge.read_bytes()).hexdigest(),
            androidAPK_SHA256=hashlib.sha256((root/'Android/app/build/outputs/apk/debug/app-debug.apk').read_bytes()).hexdigest(),
            testAPK_SHA256=hashlib.sha256((root/'Android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk').read_bytes()).hexdigest())
        (evidence/'acceptance.json').write_text(json.dumps(receipt,indent=2)+'\n')
        print(json.dumps(dict(passed=True,evidence=str(evidence))))
    finally:
        if started: host('stop')
        if (state/'host.log').exists(): shutil.copy2(state/'host.log',evidence/'private-host.log')
