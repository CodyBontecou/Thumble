#!/usr/bin/env python3
"""Verify real Rust -> Android binding hints and public CLI parity in a private recording-only runtime."""
import argparse
from datetime import datetime, timezone
import ipaddress
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial',action='append',required=True)
    parser.add_argument('--adb',required=True)
    parser.add_argument('--receiver-host',required=True)
    parser.add_argument('--host-bin',type=Path,required=True)
    parser.add_argument('--native-bin',type=Path,required=True)
    args=parser.parse_args()
    address=ipaddress.ip_address(args.receiver_host)
    assert address.version==4 and address.is_private and not address.is_loopback
    root=Path(__file__).resolve().parents[2]
    evidence=root/'Android/app/build/evidence/binding-hints-parity'/datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    evidence.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix='.tr-',dir=root) as temporary:
        task_home=Path(temporary)
        folder=task_home/'Library/Application Support/ThumbleHost';folder.mkdir(parents=True,mode=0o700)
        binary=folder/'bin';binary.mkdir(mode=0o700)
        shutil.copy2(args.host_bin,binary/'thumble-host')
        for name in ['thumble','thumble-bridge','thumble-cli-bridge']:shutil.copy2(args.native_bin/name,binary/name)
        profile=json.loads((root/'Host/fixtures/state/minimal-profile.json').read_text())
        element=profile['customization']['elements'][0]
        element['label']='Launch';element['output']={'keyboard':{'keyCode':48,'modifiersRawValue':1},'gamepadButtons':[]}
        element['presentation']={'caption':'Receiver caption'}
        profile['customization']['elements']=[element]
        profile['orientationPreference']='portrait'
        initial=dict(schemaVersion=3,configurationRevision=1,serverID='bindings-isolated-'+str(uuid.uuid4()),trustedClients={},profiles=[profile],activeProfileID=profile['id'],defaultProfileID=profile['id'])
        saved=folder/'state.json';saved.write_text(json.dumps(initial));saved.chmod(0o600)
        env=dict(os.environ,HOME=str(task_home),THUMBLE_HOST_STATE_DIR=str(folder),THUMBLE_HOST_CONTROL_SOCKET=str(folder/'control.sock'))
        def host(*arguments):
            result=subprocess.run([str(binary/'thumble-host'),*arguments],env=env,capture_output=True,text=True,timeout=30)
            if result.returncode:raise RuntimeError('Isolated receiver command failed')
            return result
        started=False
        try:
            host('start','--port','0','--no-input','--no-bonjour','--allow-config-write');started=True
            live=json.loads(host('status','--json').stdout);live=live.get('status',live)
            assert not live['inputEnabled'] and live['serverID']==initial['serverID']
            result=subprocess.run([str(binary/'thumble'),'binding','display','--profile',profile['id'],'--json'],env=env,capture_output=True,text=True,timeout=30)
            assert result.returncode==0,'Public CLI binding display failed'
            cli=json.loads(result.stdout)
            entries=cli[0]['entries']
            assert len(entries)==1 and entries[0]['compactText']=='⌘Tab' and entries[0]['accessibilityText']=='Command Tab', 'CLI disagrees with authoritative fixture'
            (evidence/'cli-binding-display.json').write_text(json.dumps(cli,indent=2)+'\n')
            qr=json.dumps(dict(type='pocketpad-pair',urls=[f"ws://{args.receiver_host}:{live['port']}"],pairingCode=live['pairingCode'],serverID=live['serverID']))
            for serial in args.serial:
                base=[args.adb,'-s',serial]
                route=subprocess.run(base+['shell','ip','route','get',args.receiver_host],capture_output=True,text=True,timeout=20)
                if not serial.startswith('emulator-'):assert 'dev wlan0' in route.stdout,'Physical phone must connect over Wi-Fi'
                for path in ['app/build/outputs/apk/debug/app-debug.apk','app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk']:
                    subprocess.run(base+['install','-r',str(root/'Android'/path)],capture_output=True,timeout=60,check=True)
                result=subprocess.run(base+['shell','am','instrument','-w','-e','class','com.thumble.android.BindingPresentationDeviceTest#realRustReceiverSendsAuthoritativeBindingMetadataToAndroidRenderer',
                    '-e','bindingPairingQR',"'"+qr.replace("'","'\\''")+"'",'com.thumble.android.test/androidx.test.runner.AndroidJUnitRunner'],capture_output=True,text=True,timeout=60)
                (evidence/(serial+'.log')).write_text(result.stdout+result.stderr)
                assert result.returncode==0 and 'OK (1 test)' in result.stdout,'Real receiver test failed; see bounded evidence'
            after=json.loads(saved.read_text())
            for field in ['profiles','activeProfileID','defaultProfileID','configurationRevision']:
                assert after[field]==initial[field],'Read-only display changed isolated configuration'
            (evidence/'verification.json').write_text(json.dumps(dict(passed=True,devices=args.serial,inputEnabled=False,normalMacRuntimeChanged=False,
                realRustToAndroid=True,publicCLIAgreement=True,configurationUnchanged=True),indent=2)+'\n')
        finally:
            if started:host('stop')
    print(json.dumps(dict(passed=True,evidence=str(evidence))))


if __name__=='__main__':main()
