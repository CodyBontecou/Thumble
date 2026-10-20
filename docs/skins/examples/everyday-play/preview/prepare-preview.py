"""Prepare a canonical Everyday Play fixture. Does not install or change app state."""
import json
import uuid
from pathlib import Path

root = Path(__file__).resolve().parent
profile = json.loads((root / 'canonical-profile.json').read_text())
profile['id'] = str(uuid.uuid5(uuid.NAMESPACE_URL, 'thumble/review/everyday-play')).upper()
profile['name'] = 'Everyday Play'
profile['orientationPreference'] = 'landscape'
profile['skinReference'] = {'identifier': 'com.thumble.everyday-play', 'version': '1.0.0'}
for key in ('customization', 'portraitCustomization', 'landscapeCustomization'):
    if key in profile:
        profile[key]['colorSchemePreference'] = 'dark'
(root / 'profile.json').write_text(json.dumps(profile, indent=2) + '\n')
print('Prepared canonical Everyday Play fixture; app state unchanged.')
