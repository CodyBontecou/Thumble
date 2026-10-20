#!/usr/bin/env python3
"""Run physical Android Wi-Fi and force-stop adoption checks without using the Mac editor's authority.

A short, owner-only child-process home is necessary because the Swift public CLI
forwards only HOME to its verified helper and rejects writable ancestry. The
normal process environment, receiver and editor are never reconfigured.
"""
import os,json,shutil,subprocess,tempfile,uuid,argparse
from datetime import datetime,timezone
from pathlib import Path
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--serial',required=True)
parser.add_argument('--adb',required=True)
parser.add_argument('--bin',type=Path,required=True)
parser.add_argument('--receiver-host',required=True)
args=parser.parse_args()
assert not args.serial.startswith('emulator-'), 'Requires a physical USB-connected Android phone'
root=Path(__file__).resolve().parents[2]
source=args.bin.resolve()
evidence=root/'Android/app/build/evidence/isolated-adoption-recovery'/datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
evidence.mkdir(parents=True)

receipts={}
with tempfile.TemporaryDirectory(prefix='.tr-', dir=root) as temporary:
 task_home=Path(temporary)
 folder=task_home/'Library/Application Support/ThumbleHost';folder.mkdir(parents=True,mode=0o700)
 binary=folder/'bin';binary.mkdir(mode=0o700)
 for name in ['thumble-host','thumble-bridge','thumble','thumble-cli-bridge']:shutil.copy2(source/name,binary/name)
 profile=json.loads((root/'Host/fixtures/state/minimal-profile.json').read_text());profile['orientationPreference']='portrait'
 initial=dict(schemaVersion=3,configurationRevision=1,serverID='adoption-isolated-'+str(uuid.uuid4()),trustedClients={},profiles=[profile],activeProfileID=profile['id'],defaultProfileID=profile['id'])
 saved=folder/'state.json';saved.write_text(json.dumps(initial));saved.chmod(0o600)
 # Configure only these child processes with a private home: the Swift CLI
 # intentionally forwards HOME alone to its verified authority helper.
 env=dict(os.environ,HOME=str(task_home),THUMBLE_HOST_STATE_DIR=str(folder),THUMBLE_HOST_CONTROL_SOCKET=str(folder/'control.sock'))
 def host(*args):
  r=subprocess.run([str(binary/'thumble-host'),*args],env=env,capture_output=True,text=True,timeout=30)
  if r.returncode:raise RuntimeError('Isolated receiver command failed')
  return r
 started=False
 try:
  host('start','--port','0','--no-input','--no-bonjour','--allow-config-write');started=True
  probe=subprocess.run([str(binary/'thumble'),'profile','list','--json'],env=env,capture_output=True,text=True,timeout=30)
  assert probe.returncode==0 and profile['id'] in probe.stdout and 'Warband Command' not in probe.stdout, 'Public CLI did not select the isolated authority'
  subprocess.run([str(binary/'thumble'),'profile','select',profile['id']],env=env,capture_output=True,text=True,timeout=30,check=True)
  runtime_probe=subprocess.run([str(binary/'thumble'),'shared-build','status',str(uuid.uuid4()),'--json'],env=env,capture_output=True,text=True,timeout=30)
  assert 'operation_missing' in runtime_probe.stderr, 'Public CLI did not reach the isolated Rust runtime'
  assert 'requires a running Rust receiver' not in runtime_probe.stderr, 'Runtime owner probe selected the wrong authority'
  for name in ['verify-wifi-adoption-recovery','verify-process-death-adoption']:
   invocation=['python3',str(root/'Android/scripts'/f'{name}.py'),'--serial',args.serial,'--adb',args.adb,'--installed-bin',str(binary),'--receiver-host',args.receiver_host,'--isolated']
   with (evidence/(name+'.log')).open('w') as log:
    r=subprocess.run(invocation,env=env,stdout=log,stderr=log,timeout=230)
   if r.returncode:raise RuntimeError(name+' failed; see its bounded test log')
   lines=(evidence/(name+'.log')).read_text().strip().splitlines()
   receipts[name]=json.loads(lines[-1])['evidence']
  (evidence/'verification.json').write_text(json.dumps(dict(passed=True,inputEnabled=False,normalRuntimeChanged=False,receipts=receipts),indent=2)+'\n')
 finally:
  if started:host('stop')
print(json.dumps(dict(passed=True,evidence=str(evidence),receipts=receipts)))
