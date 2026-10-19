#!/usr/bin/env python3
"""Stage-verified local receiver update with private backups and binary rollback.

Default is a read-only preflight. --install updates the existing per-user receiver,
preserving its state, port, Bonjour, input and configuration-write settings.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--staged-bin', type=Path, required=True)
parser.add_argument('--state-dir', type=Path, default=Path.home() / 'Library/Application Support/ThumbleHost')
parser.add_argument('--receipt', type=Path, required=True)
parser.add_argument('--install', action='store_true')
args = parser.parse_args()
state_dir = args.state_dir.resolve()
bin_dir = state_dir / 'bin'
installed_host = bin_dir / 'thumble-host'
names = ['thumble-host', 'thumble', 'thumble-cli-bridge', 'thumble-bridge']
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
def command(*values):
    result = subprocess.run([str(installed_host), *values], capture_output=True, text=True,
        env=dict(os.environ, THUMBLE_HOST_STATE_DIR=str(state_dir), THUMBLE_HOST_CONTROL_SOCKET=str(state_dir / 'control.sock')))
    if result.returncode:
        raise RuntimeError('Receiver lifecycle command failed')
    return result.stdout
def status():
    value = json.loads(command('status', '--json'))
    return value.get('status', value.get('response', {}).get('status', value))
def ready():
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            value = status()
            if value.get('port') and 'inputEnabled' in value:
                return value
        except (RuntimeError, ValueError):
            pass
        time.sleep(.05)
    raise RuntimeError('Receiver did not publish ready status')
for name in names:
    source = args.staged_bin / name
    target = bin_dir / name
    for path in [source, target]:
        assert path.is_file() and not path.is_symlink() and os.access(path, os.X_OK), f'Not a regular executable: {path.name}'
    subprocess.run(['codesign', '--verify', '--strict', str(source)], capture_output=True, check=True)
before = ready()
assert not before['core']['paired'], 'A phone is paired; receiver update deferred'
assert not before['output']['heldKeyCount'] and not before['output']['heldPointerButtons'], 'Input is held; receiver update deferred'
state_file = state_dir / 'state.json'
original_bytes = state_file.read_bytes()
original = json.loads(original_bytes)
settings = dict(port=before['requestedPort'], bonjour=before['bonjour']['enabled'],
                input=before['inputEnabled'], configurationWrite=before['configurationWriteEnabled'])
start = ['start', '--port', str(settings['port'])]
if not settings['bonjour']:
    start.append('--no-bonjour')
if not settings['input']:
    start.append('--no-input')
if settings['configurationWrite']:
    start.append('--allow-config-write')
old_hashes = {name: digest(bin_dir / name) for name in names}
new_hashes = {name: digest(args.staged_bin / name) for name in names}
print(json.dumps(dict(preflight='passed', installRequested=args.install, settings=settings,
    profileCount=len(original['profiles']), changedBinaries=[name for name in names if old_hashes[name] != new_hashes[name]])))
if not args.install:
    raise SystemExit(0)
backup = state_dir / 'backups' / ('android-parity-launch-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
backup.mkdir(parents=True, mode=0o700)
(backup / 'bin').mkdir(mode=0o700)
shutil.copy2(state_file, backup / 'state.json')
(backup / 'state.json').chmod(0o600)
for name in names:
    shutil.copy2(bin_dir / name, backup / 'bin' / name)
(backup / 'manifest.json').write_text(json.dumps(dict(oldSHA256=old_hashes, settings=settings, stateSHA256=hashlib.sha256(original_bytes).hexdigest()),indent=2) + '\n')
(backup / 'manifest.json').chmod(0o600)
stopped = False
try:
    current = ready()
    assert not current['core']['paired'] and not current['output']['heldKeyCount'] and not current['output']['heldPointerButtons'], 'Receiver became busy; update deferred'
    assert state_file.read_bytes() == original_bytes, 'State changed during preflight; update deferred'
    command('stop')
    stopped = True
    for name in names:
        temporary = bin_dir / (name + '.android-update')
        shutil.copy2(args.staged_bin / name, temporary)
        temporary.chmod(0o755)
        os.replace(temporary, bin_dir / name)
        assert digest(bin_dir / name) == new_hashes[name], 'Installed binary differs from its verified stage'
    command(*start)
    after = ready()
    assert after['inputEnabled'] == settings['input']
    assert after['accessibilityTrusted'] or not before['accessibilityTrusted'], 'Updated binary needs a new Accessibility grant'
    assert after['bonjour']['enabled'] == settings['bonjour']
    assert after['configurationWriteEnabled'] == settings['configurationWrite']
    assert after['requestedPort'] == settings['port']
    assert not after['core']['paired'] and not after['output']['heldKeyCount'] and not after['output']['heldPointerButtons']
    assert json.loads(state_file.read_bytes()) == original, 'State changed during update; backup preserved for review'
except BaseException:
    if stopped:
        try:
            command('stop')
        finally:
            for name in names:
                temporary = bin_dir / (name + '.android-rollback')
                shutil.copy2(backup / 'bin' / name, temporary)
                os.replace(temporary, bin_dir / name)
            command(*start)
            ready()
    raise
receipt = dict(installed=True, backup=str(backup), oldSHA256=old_hashes, installedSHA256=new_hashes,
               settingsPreserved=settings, profilesAndTrustUnchanged=True, paired=False,
               heldKeyCount=0, heldPointerButtons=[], accessibilityTrusted=after['accessibilityTrusted'])
args.receipt.parent.mkdir(parents=True, exist_ok=True)
args.receipt.write_text(json.dumps(receipt, indent=2) + '\n')
print('Installed tested receiver update; settings, profiles and trust preserved; no held input.')
print('Receipt:', args.receipt)
