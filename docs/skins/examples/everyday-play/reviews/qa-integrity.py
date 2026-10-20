"""Read-only final Everyday Play integrity QA; run from repository root."""
import hashlib
import json
import pathlib
import struct
root = pathlib.Path('/tmp/thumble-everyday-qa/unpacked')
workspace = pathlib.Path('docs/skins/examples/everyday-play')
manifest = json.loads((root/'manifest.json').read_text())
assert len(manifest['assets']) == 4
for asset in manifest['assets']:
    path = root/asset['path']
    assert path.resolve().is_relative_to(root.resolve())
    data = path.read_bytes()
    assert hashlib.sha256(data).hexdigest() == asset['sha256']
    assert len(data) == asset['byteCount']
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    size = struct.unpack('>II', data[16:24])
    assert size in [(1748,804),(804,1748)]
    print(asset['path'],size,len(data),asset['sha256'])
assert hashlib.sha256((root/'skin.json').read_bytes()).hexdigest() == manifest['skinSHA256']
files = {str(path.relative_to(root)) for path in root.rglob('*') if path.is_file()}
assert files == {'manifest.json','skin.json',*(a['path'] for a in manifest['assets'])}
assert not any(path.is_symlink() for path in root.rglob('*'))
skin = json.loads((root/'skin.json').read_text())
assert set(skin) == {'base','variants'}
def inspect(value):
    if isinstance(value,dict):
        for key, child in value.items():
            assert not any(word in key.lower() for word in ['binding','script','profile','macro','keycode','gamepadoutput']), key
            inspect(child)
    elif isinstance(value,list):
        for child in value: inspect(child)
inspect(skin)
source = json.loads((workspace/'skin-source.json').read_text())
assert source['artboardID'] == 'classic-16-bit-v1'
assert len(source['sourceAssets']) == 4
for asset in source['sourceAssets']:
    assert asset['path'].endswith('.svg')
    assert (workspace/asset['path']).is_file()
for sheet in source['stylesheets']:
    assert (workspace/sheet).is_file()
compat = manifest['compatibility']
assert set(compat['orientations']) == {'landscape','portrait'}
assert compat['templates'] == [{'templateID':'snes','minimumRevision':2,'maximumRevision':2}]
contrast = json.loads((workspace/'reviews/contrast-1.json').read_text())
assert all(row['ratio'] >= row['threshold'] for row in contrast['results'])
approval = json.loads((workspace/'reviews/human-approval.json').read_text())
assert approval['status'] == 'pending'
assert all(approval[key] is None for key in ['approvedBy','approvedAt','reviewedContactSheet','packageSHA256'])
print('PASS: 4 PNG hashes/dimensions/byte counts; skin hash; appearance-only file allowlist; no scripts/profile/binding payload or symlinks; retained editable SVG/CSS; canonical revision2 metadata; recorded contrast thresholds; pending approval.')
print('Total unpacked bytes:',sum((root/file).stat().st_size for file in files))
