"""Create disposable native-app fixtures; does not install or change user profiles.

These are appearance examples, not WoW spell assignments or live action-bar data.
"""
import copy
import json
import plistlib
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[5]
OUT = Path(__file__).resolve().parent
profile = copy.deepcopy(json.loads((OUT / 'canonical-profile.json').read_text()))
profile['id'] = str(uuid.uuid5(uuid.NAMESPACE_URL, 'thumble/review/warband-command')).upper()
profile['name'] = 'Warband Command · Warrior'
profile['orientationPreference'] = 'landscape'
profile['skinReference'] = {'identifier': 'com.thumble.warband-command', 'version': '1.0.2'}
for key in ('customization', 'portraitCustomization', 'landscapeCustomization'):
    if key in profile:
        profile[key]['colorSchemePreference'] = 'dark'
state = {'profiles': [profile], 'activeProfileID': profile['id'], 'defaultProfileID': profile['id']}
prefs = {
    'PocketPad.gamepadConfigurationProfiles.v1': json.dumps(state).encode(),
    'PocketPad.gamepadCustomization.v1': json.dumps(profile['customization']).encode(),
    'PocketPad.iOS.hasSavedKeypadSnapshot.v1': True,
    'PocketPad.iOS.onboarding.completed.v1': True,
    'PocketPad.iOS.discordPromoDismissed.v1': True,
    'PocketPad.iOS.showBindingGlyphs.v1': True,
    'PocketPad.iOS.immersiveKeypad.v1': True,
    'PocketPad.iOS.practiceMode.v1': True,
    'PocketPad.iOS.bindingPresentations.v1': b'[]',
}
(OUT / 'profile.json').write_text(json.dumps(profile, indent=2) + '\n')
(OUT / 'preferences.plist').write_bytes(plistlib.dumps(prefs))
print('Prepared isolated Warrior review profile and Practice Mode preferences.')
