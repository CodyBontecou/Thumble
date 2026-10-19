"""Prepare canonical portrait profiles for isolated native Fury Forge captures.

The existing appearance-only package must be copied into the capture app's SkinStore.
This script never modifies the package, canonical geometry, or executable bindings.
"""
import copy
import json
import plistlib
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
OUT = Path(__file__).parent / 'profiles'
OUT.mkdir(exist_ok=True)
base = json.loads((ROOT / 'Host/fixtures/controller-templates/v1/wowForever.json').read_text())['profile']
profiles = []
for name, filename in (
    ('Fury Warrior', 'fury-warrior.json'),
    ('Fury — Solo', 'fury-solo.json'),
    ('Fury — Group', 'fury-group.json'),
):
    profile = copy.deepcopy(base)
    profile['id'] = str(uuid.uuid5(uuid.NAMESPACE_URL, 'thumble-marketing/gaming/' + name)).upper()
    profile['name'] = name
    profile['orientationPreference'] = 'portrait'
    profile['skinReference'] = {'identifier': 'com.thumble.fury-forge', 'version': '1.0.0'}
    for key in ('customization', 'portraitCustomization', 'landscapeCustomization'):
        if key in profile:
            profile[key]['colorSchemePreference'] = 'dark'
    profiles.append(profile)
    (OUT / filename).write_text(json.dumps(profile, indent=2, ensure_ascii=False) + '\n')

# Remove obsolete capture fixtures to prevent accidental generic-layout reuse.
for filename in ('wow-forever.json', 'frost-mage.json'):
    (OUT / filename).unlink(missing_ok=True)
selected = profiles[0]
state = {'profiles': profiles, 'activeProfileID': selected['id'], 'defaultProfileID': selected['id']}
prefs = {
    'PocketPad.gamepadConfigurationProfiles.v1': json.dumps(state).encode(),
    'PocketPad.gamepadCustomization.v1': json.dumps(selected['customization']).encode(),
    'PocketPad.iOS.hasSavedKeypadSnapshot.v1': True,
    'PocketPad.iOS.onboarding.completed.v1': True,
    'PocketPad.iOS.discordPromoDismissed.v1': True,
    'PocketPad.iOS.showBindingGlyphs.v1': True,
    'PocketPad.iOS.immersiveKeypad.v1': True,
    'PocketPad.iOS.practiceMode.v1': True,
    'PocketPad.iOS.bindingPresentations.v1': b'[]',
}
(OUT / 'gaming-preferences.plist').write_bytes(plistlib.dumps(prefs))
print('Prepared three portrait Fury Forge profiles with unchanged canonical geometry and inputs.')
