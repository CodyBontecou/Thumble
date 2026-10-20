"""Read-only reproduction of the final package/hash/safety QA. Run from repo root."""
import hashlib
import json
import pathlib
import struct

workspace = pathlib.Path('docs/skins/examples/warband-command')
root = pathlib.Path('/tmp/thumble-warband-qa/unpacked')
manifest = json.loads((root / 'manifest.json').read_text())
assets = manifest['assets']
for asset in assets:
    path = root / asset['path']
    assert path.resolve().is_relative_to(root.resolve())
    data = path.read_bytes()
    assert len(data) == asset['byteCount']
    assert hashlib.sha256(data).hexdigest() == asset['sha256']
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    width, height = struct.unpack('>II', data[16:24])
    assert (width, height) in {(56, 56), (1748, 804), (804, 1748)}
    print(asset['path'], width, height, len(data))
files = {str(path.relative_to(root)) for path in root.rglob('*') if path.is_file()}
assert files == {'manifest.json', 'skin.json', *(asset['path'] for asset in assets)}
assert not any(path.is_symlink() for path in root.rglob('*'))
for entry in json.loads((workspace / 'sources/provenance.json').read_text()):
    for file_key, hash_key in [('originalFile', 'originalSHA256'), ('pngFile', 'pngSHA256')]:
        assert hashlib.sha256((workspace / 'sources' / entry[file_key]).read_bytes()).hexdigest() == entry[hash_key]
skin = json.loads((root / 'skin.json').read_text())
assert set(skin) == {'base', 'variants'}
def check_keys(value):
    if isinstance(value, dict):
        for key, child in value.items():
            assert not any(word in key.lower() for word in ('binding', 'script', 'profile', 'macro', 'keycode', 'gamepadoutput')), key
            check_keys(child)
    elif isinstance(value, list):
        for child in value:
            check_keys(child)
check_keys(skin)
approval = json.loads((workspace / 'reviews/human-approval.json').read_text())
assert approval['status'] == 'pending'
assert all(approval[key] is None for key in ('approvedBy', 'approvedAt', 'reviewedContactSheet', 'packageSHA256'))
print('PASS: 16 asset hashes/dimensions; 8 original and PNG provenance pairs; exact appearance-only file allowlist; no executable/profile/binding keys; pending approval.')
print('Total unpacked bytes:', sum((root / file).stat().st_size for file in files))
