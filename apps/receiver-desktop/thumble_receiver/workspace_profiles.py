"""Desktop transactions over the same locked store used by phone and agents."""
from copy import deepcopy
import math

from .profiles import MAX_REVISION, encoded, matches, require, validate_profile
from .state import integer, number


def validate_layout(profile, viewport):
    validate_profile(profile)
    require(profile['name'].strip(), 'Give this controller a name.')
    require(isinstance(viewport, dict) and set(viewport) == {'width', 'height'})
    require(all(number(viewport[k]) and 0 < viewport[k] <= 10000 for k in viewport))
    areas = []
    for control in profile['controls']:
        f = control['frame']; w, h = viewport['width'], viewport['height']
        x, y, width, height = f['x'] * w, f['y'] * h, f['width'] * w, f['height'] * h
        minimum = 96 if control['type'] == 'stick' else 48
        require(min(width, height) + .001 >= minimum, 'Enlarge controls to the minimum touch target.')
        radius = 0
        if control['type'] == 'stick':
            side = min(width, height); x += (width - side) / 2; y += (height - side) / 2
            width = height = side; radius = side / 2
        areas.append((x, y, width, height, radius))
    reserved = [(viewport['width'] - 44, 4, 44, 44, 0)]
    if not any(c['id'] == 'chat' for c in profile['controls']):
        reserved.append((viewport['width'] / 2 - 26, 4, 52, 44, 0))
    def overlap(a, b):
        x,y,w,h,r = a; X,Y,W,H,R = b
        if r and R:
            return math.hypot(x+r-X-R, y+r-Y-R) < r+R-.001
        if r or R:
            circle,box = (a,b) if r else (b,a)
            cx,cy,_,_,radius = circle; bx,by,bw,bh,_ = box
            cx += radius; cy += radius
            return math.hypot(cx-max(bx,min(cx,bx+bw)), cy-max(by,min(cy,by+bh))) < radius-.001
        return min(x+w,X+W)-max(x,X) > .001 and min(y+h,Y+H)-max(y,Y) > .001
    for index, area in enumerate(areas):
        require(not any(overlap(area, other) for other in areas[index+1:] + reserved), 'Separate overlapping controls and keep the menu areas clear.')


def editable(entry):
    return not entry.get('cloudSource') and (entry.get('desktopEdited') is True or entry.get('phoneEdited') is True)


class WorkspaceProfiles:
    def __init__(self, store):
        self.store = store

    def snapshot(self):
        data = self.store.read()
        return dict(profiles=[dict(profile=deepcopy(e['profile']), revision=e['revision'], editable=editable(e)) for e in data['profiles']],
                    active=deepcopy(data.get('active')), activationRevision=(data.get('active') or {}).get('revision', 0))

    def save(self, profile, expected, viewport):
        validate_layout(profile, viewport)
        require(integer(expected), 'Invalid controller revision.')
        with self.store.transaction() as store:
            entry = next((e for e in store['profiles'] if e['profile']['id'] == profile['id']), None)
            if entry:
                require(editable(entry), 'Save a copy of built-in or synced controllers.')
                require(entry['revision'] == expected and expected < MAX_REVISION, 'This controller changed elsewhere. Reopen it before saving.')
                if encoded(entry['profile']) != encoded(profile):
                    entry['profile'] = deepcopy(profile); entry['revision'] += 1
            else:
                require(expected == 0 and matches(profile['id'], r'desktop-[a-f0-9]{32}'))
                require(len(store['profiles']) < 256, 'Profile limit reached.')
                store['profiles'].append(dict(profile=deepcopy(profile), revision=1, desktopEdited=True))
        return self.snapshot()

    def delete(self, profile_id, expected, activation):
        require(integer(expected, 1))
        with self.store.transaction() as store:
            self.store.expect(store, activation)
            require((store.get('active') or {}).get('profile', {}).get('id') != profile_id, 'Select another controller before deleting this one.')
            entry = next((e for e in store['profiles'] if e['profile']['id'] == profile_id), None)
            require(entry and editable(entry), 'Original controllers cannot be removed.')
            require(entry['revision'] == expected, 'This controller changed elsewhere. Refresh before deleting.')
            store['profiles'].remove(entry)
        return self.snapshot()

    def activate(self, profile_id, revision, activation, viewport):
        # Validate the selected revision under the transaction lock in select;
        # a concurrent edit invalidates revision rather than silently activating it.
        entry = next((e for e in self.store.read()['profiles'] if e['profile']['id'] == profile_id), None)
        require(entry is not None, 'Controller no longer exists.')
        validate_layout(entry['profile'], viewport)
        self.store.select(profile_id, revision, activation)
        return self.snapshot()
