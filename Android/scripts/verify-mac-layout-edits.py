#!/usr/bin/env python3
"""Verify Android active/inactive/recovered layout sync against a private Rust Mac receiver.

Uses memory-only Android session state and a no-input, no-Bonjour receiver.
Pairing data remains in memory and never enters the receipt or command output.
"""
import argparse
import base64
import time
import zipfile
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
parser.add_argument('--without-skin-library',action='store_true')
parser.add_argument('--editor-ui',action='store_true',help='Exercise the visible editor instead of the client API')
parser.add_argument('--skin',type=Path,help='Apply an existing unchanged package before editor UI acceptance')
parser.add_argument('--template',choices=['productivityStarter','arcadeStick'],default='productivityStarter')
parser.add_argument('--custom-control',action='store_true',help='Exercise a declared custom button in the visible editor')
a=parser.parse_args()
assert not a.custom_control or a.editor_ui,'Custom control acceptance requires editor UI'
assert a.editor_ui or a.template=='productivityStarter','Template selection requires editor UI'
assert not a.skin or (a.editor_ui and not a.without_skin_library),'Skin acceptance requires editor UI and an available archive library'
root=Path(__file__).resolve().parents[2]
evidence=root/'Android/app/build/evidence/layout-receiver'/datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
evidence.mkdir(parents=True,exist_ok=False)
base=[a.adb,'-s',a.serial]

def adb(*args):
    result=subprocess.run(base+list(args),capture_output=True,text=True)
    if result.returncode:raise RuntimeError('Device setup failed; pairing arguments withheld')
    return result.stdout

with tempfile.TemporaryDirectory(prefix='thumble-layout-') as d:
    folder=Path(d);binary=folder/'bin';binary.mkdir(mode=0o700)
    executable=binary/'thumble-host';shutil.copy2(a.host,executable)
    shutil.copy2(a.bridge,binary/'thumble-bridge')
    state=folder/'state';state.mkdir(mode=0o700)
    env=dict(os.environ,THUMBLE_HOST_STATE_DIR=str(state),THUMBLE_HOST_CONTROL_SOCKET=str(folder/'control.sock'))
    profile=json.loads((root/f'Host/fixtures/controller-templates/v1/{a.template}.json').read_text())['profile']
    profile['customization']['colorSchemePreference']='system'
    if a.editor_ui:profile['orientationPreference']='portrait'
    if a.custom_control:
        layout=profile.get('portraitCustomization',profile['customization'])
        custom_ids=json.loads((root/f'Host/fixtures/controller-templates/v1/{a.template}.json').read_text())['customElementIDs']
        controls=[e['id'] for e in layout['elements'] if e['id'] in custom_ids and e.get('kind')=='button' and not e.get('layout',{}).get('isLocationLocked',False)]
        assert len(controls)>=2,'This fixture needs two declared custom buttons'
        def identity(value):return dict(kind='custom',id=value)
        layout['designMetadata']['groups']=[
            dict(id=str(uuid.uuid5(uuid.NAMESPACE_URL,'thumble-editor-single-group')).upper(),name='Deleted group',children=[identity(controls[0])],isLocked=False,isHidden=False),
            dict(id=str(uuid.uuid5(uuid.NAMESPACE_URL,'thumble-editor-retained-group')).upper(),name='Retained group',children=[identity(controls[0]),identity(controls[1])],isLocked=False,isHidden=False),
        ]

    inactive=json.loads((root/'Host/fixtures/controller-templates/v1/gameBoy.json').read_text())['profile']
    inactive['id']='4FD20F4A-3C83-40B5-87C0-64512F4AC925'
    inactive['customization']['colorSchemePreference']='system'
    initial=dict(schemaVersion=3,configurationRevision=1,serverID='layout-acceptance-'+str(uuid.uuid4()),trustedClients={},
        profiles=[profile,inactive],activeProfileID=profile['id'],defaultProfileID=profile['id'])
    saved=state/'state.json';saved.write_text(json.dumps(initial));saved.chmod(0o600)
    if a.without_skin_library:
        (state/'skins').write_text('Private fixture: unavailable archive store')
        (state/'skins').chmod(0o600)
    def host(*args):
        result=subprocess.run([str(executable),*args],env=env,capture_output=True,text=True)
        if result.returncode:raise RuntimeError('Private receiver command failed')
        return result.stdout
    started=False
    try:
        host('start','--port','0','--no-input','--no-bonjour');started=True
        skin_reference=None;owned_asset_data=[]
        if a.skin:
            with zipfile.ZipFile(a.skin) as archive:
                manifest=json.loads(archive.read('manifest.json'))
                skin_reference=manifest['identifier']+'@'+manifest['version']
                owned_asset_data=[base64.b64encode(archive.read(n)).decode() for n in archive.namelist() if n.startswith('assets/') and not n.endswith('/')]
            host('skin','import',str(a.skin.resolve()),'--replace')
            host('skin','apply',skin_reference,'--profile','active','--appearance','light')
        before=json.loads(saved.read_text())
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
        if a.editor_ui:
            adb('shell','rm','-f',*[f'/sdcard/Android/data/com.thumble.android/files/layout-editor-{name}' for name in
                ['live-diagnostic.json','android-saved-layout.json','android-pending-layout.json','live-failure.png','live-entry.png','live-synced.png','live-offline.png','live-reconnected.png','live-deleted.png']])
        with (evidence/'instrumentation.log').open('w') as log:
            try:
                result=subprocess.run(base+['shell','am','instrument','-w','-e','class',
                'com.thumble.android.LayoutEditorDeviceTest#realMacEditorSyncsUndoCancelAndOfflineGeometry' if a.editor_ui else
                'com.thumble.android.LayoutEditClientDeviceTest#realRustReceiverAcceptsActiveInactiveAndRecoveredLayouts',
                '-e','layoutEditorSkinReference',skin_reference or 'none',
                '-e','layoutEditorCustomControl',str(a.custom_control).lower(),
                '-e','expectLayoutSkinLibraryUnavailable',str(a.without_skin_library).lower(),
                '-e','layoutEditorPairingQR' if a.editor_ui else 'layoutPairingQR',"'"+qr.replace("'","'\\''")+"'",'com.thumble.android.test/androidx.test.runner.AndroidJUnitRunner'],stdout=log,stderr=log,timeout=150)
            except subprocess.TimeoutExpired:
                adb('shell','am','force-stop','com.thumble.android')
                raise RuntimeError('Real receiver instrumentation timed out; pairing arguments withheld') from None
        report=(evidence/'instrumentation.log').read_text()
        if result.returncode!=0 or 'OK (1 test)' not in report:
            failed=json.loads(saved.read_text())
            # This is the explicit public-template fixture, never normal Mac state.
            (evidence/'before-fixture-profile.json').write_text(json.dumps(before['profiles'][0],indent=2))
            (evidence/'failed-fixture-profile.json').write_text(json.dumps(failed['profiles'][0],indent=2))
            if a.editor_ui:
                for name in ['live-diagnostic.json','android-saved-layout.json','android-pending-layout.json','live-failure.png']:
                    subprocess.run(base+['pull','/sdcard/Android/data/com.thumble.android/files/layout-editor-'+name,str(evidence/name)],capture_output=True)
        assert result.returncode==0 and 'OK (1 test)' in report,'Real receiver acceptance failed; see instrumentation log'
        final=json.loads(saved.read_text())
        assert final['profiles'][0]['id']==profile['id']
        if a.editor_ui:
            active=final['profiles'][0];baseline=before['profiles'][0]
            assert len(final['profiles'])==2 and final['profiles'][1]==before['profiles'][1]
            assert active['portraitCustomization']!=baseline.get('portraitCustomization',baseline['customization'])
            allowed={'customization','portraitCustomization','landscapeCustomization','updatedAt'}
            assert {k:v for k,v in active.items() if k not in allowed}=={k:v for k,v in baseline.items() if k not in allowed}
            assert final['configurationRevision']>=before['configurationRevision']+11
            for data in owned_asset_data:assert not data or data not in json.dumps(final['profiles'])
            if a.skin:
                exported=folder/'exact.pocketpad';host('skin','export',skin_reference,'-o',str(exported))
                assert exported.read_bytes()==a.skin.read_bytes()
            for _ in range(50):
                current=json.loads(host('status','--json'));current=current.get('status',current)
                if not current['core']['paired']:break
                time.sleep(.1)
            assert not current['core']['paired']
            host('stop');started=False
            host('start','--port',str(status['port']),'--no-input','--no-bonjour');started=True
            restarted=json.loads(saved.read_text())
            assert restarted['profiles']==final['profiles'] and restarted['configurationRevision']==final['configurationRevision']
            catalog=json.loads(host('profiles','--json'))
            assert catalog['profiles'][0]['id']==profile['id']
            device=evidence/'device';device.mkdir()
            for name in ['live-entry','live-synced','live-offline','live-reconnected','live-deleted']:
                adb('pull','/sdcard/Android/data/com.thumble.android/files/layout-editor-'+name+'.png',str(device/(name+'.png')))
        else:
            assert final['profiles'][0]['portraitCustomization']['showsButtonLabels'] != profile['customization']['showsButtonLabels']
            assert final['profiles'][1]['id']==inactive['id']
            assert final['profiles'][1]['landscapeCustomization']['showsButtonLabels'] != inactive['customization']['showsButtonLabels']
            recovered=[p for p in final['profiles'] if p['id'].lower()=='4fd20f4a-3c83-40b5-87c0-64512f4ac926']
            assert len(final['profiles'])==3 and len(recovered)==1 and recovered[0]['name']=='Recovered Phone Layout'
        assert final['activeProfileID']==profile['id'] and final['defaultProfileID']==profile['id']
        assert final['configurationRevision']>=4
        current=json.loads(host('status','--json'));current=current.get('status',current)
        assert current['inputEnabled'] is False
        assert current['output']['heldKeyCount']==0
        receipt=dict(passed=True,serialKind='emulator' if a.serial.startswith('emulator-') else 'physical',
            inputEnabled=False,heldKeys=0,configurationRevision=final['configurationRevision'],
            activePortraitEdit=True,inactiveEditWithoutSelection=not a.editor_ui,recoveredDeletedLayout=not a.editor_ui,profileIdentityPreserved=True,
            visibleEditorUI=a.editor_ui,undoAndCancelAcknowledged=a.editor_ui,
            customControlUI=a.custom_control,customControlGroupsVerified=a.custom_control,template=a.template,resizeRotateDeleteAcknowledged=a.editor_ui,offlineUIReconnectAcknowledged=a.editor_ui,
            receiverRestartPreservesEdits=a.editor_ui,skinReference=skin_reference,
            skinPackageSHA256=hashlib.sha256(a.skin.read_bytes()).hexdigest() if a.skin else None,
            ownedPackageAssetDataNotPersisted=bool(a.skin),
            skinLibraryUnavailableFixture=a.without_skin_library,
            hostSHA256=hashlib.sha256(a.host.read_bytes()).hexdigest(),
            bridgeSHA256=hashlib.sha256(a.bridge.read_bytes()).hexdigest(),
            androidSession='memory-only',normalMacInstallationChanged=False)
        (evidence/'acceptance.json').write_text(json.dumps(receipt,indent=2)+'\n')
        print(json.dumps(dict(passed=True,evidence=str(evidence),configurationRevision=final['configurationRevision'])))
    finally:
        if started:host('stop')
        if (state/'host.log').exists():shutil.copy2(state/'host.log',evidence/'private-host.log')
