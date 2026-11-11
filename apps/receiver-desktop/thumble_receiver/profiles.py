"""Validated declarative profiles and the shared local-agent store contract."""
from contextlib import contextmanager
from copy import deepcopy
import hashlib
from importlib.resources import files
import json
from pathlib import Path
import re
import time
from urllib.parse import urlsplit

from .access import atomic_json
from .clock import monotonic
from .state import integer, number

BUTTONS = set('a b x y lb rb back start ls rs up down left right guide'.split())
AXES = {'lx', 'ly', 'rx', 'ry'}
TRIGGERS = {'lt', 'rt'}
MODIFIERS = {'', 'SHIFT-', 'CTRL-', 'ALT-', 'CTRL-SHIFT-', 'ALT-SHIFT-', 'ALT-CTRL-', 'ALT-CTRL-SHIFT-'}
MAX_REVISION = 9_007_199_254_740_991
DESKTOP_KEYS = {'key:' + key['code'] for key in json.loads(files('thumble_receiver').joinpath('DesktopKeys.json').read_bytes())}


class ProfileError(ValueError):
    pass


def require(condition, message='Invalid controller profile.'):
    if not condition:
        raise ProfileError(message)


def only(value, keys):
    return isinstance(value, dict) and set(value) <= set(keys)


def text(value):
    return isinstance(value, str) and 1 <= len(value.encode('utf-16-le')) // 2 <= 80


def matches(value, pattern):
    return isinstance(value, str) and re.fullmatch(pattern, value) is not None


def slug(value):
    return matches(value, r'[a-z0-9][a-z0-9-]{0,63}')


def finite(value, minimum, maximum):
    return number(value) and minimum <= value <= maximum


def encoded(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False, sort_keys=True,
                      separators=(',', ':')).encode('utf-8')


def load_json(data):
    def invalid(_):
        raise ProfileError('Non-finite JSON value.')

    def object_pairs(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, 'Duplicate JSON field.')
            result[key] = value
        return result

    return json.loads(data, parse_constant=invalid, object_pairs_hook=object_pairs)


def bounded_read(path, limit):
    with open(path, 'rb') as stream:
        data = stream.read(limit + 1)
    require(len(data) <= limit, 'File exceeds its size limit.')
    return data


def validate_profile(profile):
    require(only(profile, ('schemaVersion', 'id', 'name', 'controls', 'mappings', 'theme', 'modifiers')))
    require(integer(profile.get('schemaVersion'), 1, 1) and slug(profile.get('id')) and text(profile.get('name')))
    require('theme' not in profile or profile['theme'] == 'consoleport')
    if 'modifiers' in profile:
        mods = profile['modifiers']
        require(only(mods, ('shift', 'ctrl', 'alt')) and all(
            isinstance(value, str) and value in BUTTONS | TRIGGERS | {'none'} for value in mods.values()))
    controls, mappings = profile.get('controls'), profile.get('mappings')
    require(isinstance(controls, list) and 1 <= len(controls) <= 64)
    require(isinstance(mappings, list) and len(mappings) == len(controls))
    require(len(encoded(profile)) <= 60000, 'Profile exceeds 60000 bytes.')
    ids = {}
    for control in controls:
        require(only(control, ('id', 'type', 'label', 'customLabel', 'frame', 'color', 'icon', 'badge', 'layers')))
        require(text(control.get('id')) and text(control.get('label')))
        require(control['id'] not in ids and control.get('type') in ('button', 'trigger', 'stick', 'key', 'mouse', 'trackpad'))
        frame = control.get('frame')
        require(only(frame, ('x', 'y', 'width', 'height')))
        require(all(finite(frame.get(key), 0, 1) for key in ('x', 'y')))
        require(all(finite(frame.get(key), 0.01, 1) for key in ('width', 'height')))
        require(frame['x'] + frame['width'] <= 1.000001 and frame['y'] + frame['height'] <= 1.000001)
        for key, pattern in (('color', r'#[0-9a-fA-F]{6}'), ('icon', r'[a-z0-9_]{1,128}')):
            require(key not in control or matches(control[key], pattern))
        require('badge' not in control or text(control['badge']))
        require('customLabel' not in control or text(control['customLabel']))
        if 'layers' in control:
            layers = control['layers']
            require(only(layers, MODIFIERS))
            for layer in layers.values():
                require(only(layer, ('label', 'icon')) and text(layer.get('label')))
                require('icon' not in layer or matches(layer['icon'], r'[a-z0-9_]{1,128}'))
        ids[control['id']] = control['type']
    mapped, owned = set(), set()
    for mapping in mappings:
        require(only(mapping, ('controlId', 'outputs', 'deadzone', 'sensitivity', 'invertX', 'invertY')))
        control_id, outputs = mapping.get('controlId'), mapping.get('outputs')
        require(isinstance(control_id, str) and control_id in ids and control_id not in mapped)
        require(isinstance(outputs, list) and all(isinstance(value, str) for value in outputs))
        kind = ids[control_id]
        if kind == 'button':
            require(len(outputs) == 1 and outputs[0] in BUTTONS)
        elif kind == 'trigger':
            require(len(outputs) == 1 and outputs[0] in TRIGGERS)
        elif kind == 'key':
            require(1 <= len(outputs) <= 6 and len(set(outputs)) == len(outputs) and set(outputs) <= DESKTOP_KEYS)
        elif kind == 'mouse':
            require(len(outputs) == 1 and outputs[0] in ('mouse:left', 'mouse:right', 'mouse:middle'))
        elif kind == 'trackpad':
            require(outputs == ['pointer'])
        else:
            require(outputs in (['lx', 'ly'], ['rx', 'ry']))
        for key, low, high in (('deadzone', 0, 0.5), ('sensitivity', 0.1, 3)):
            require(key not in mapping or ((kind == 'stick' or (key == 'sensitivity' and kind == 'trackpad')) and finite(mapping[key], low, high)))
        for key in ('invertX', 'invertY'):
            require(key not in mapping or (kind == 'stick' and type(mapping[key]) is bool))
        for output in outputs:
            if output in AXES | TRIGGERS:
                require(output not in owned)
                owned.add(output)
        mapped.add(control_id)
    return deepcopy(profile)


def cloud_id(source, profile):
    require(only(source, ('service', 'accountId', 'profileId', 'revision')) and len(source) == 4)
    service = source.get('service')
    require(isinstance(service, str) and len(service.encode()) <= 2048)
    require(not any(character.isspace() or ord(character) < 32 for character in service))
    require(not any(character in service for character in ('?', '#', '\\')))
    url = urlsplit(service)
    require(url.scheme == 'https' and bool(url.hostname) and url.username is None and url.password is None)
    _ = url.port  # Reject invalid ports/IPv6 before deriving a local ID.
    require(matches(source.get('accountId'), r'[a-f0-9]{64}') and slug(source.get('profileId'))
            and source.get('profileId') == profile['id'])
    require(integer(source.get('revision'), 1))
    # Match Foundation's sorted JSON serialization, including escaped slashes.
    data = encoded(source).replace(b'/', b'\\/')
    return 'cloud-' + hashlib.sha256(data).hexdigest()[:40]


class ProfileStore:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.builtins = load_json(files('thumble_receiver').joinpath('BuiltInProfiles.json').read_bytes())
        require(isinstance(self.builtins, list))
        for profile in self.builtins:
            validate_profile(profile)

    def read(self):
        try:
            store = load_json(bounded_read(self.directory / 'store.json', 8 * 1024 * 1024))
        except FileNotFoundError:
            store = dict(version=1, profiles=[], active=None)
        require(isinstance(store, dict) and integer(store.get('version'), 1, 1), 'Invalid profile store.')
        entries = store.get('profiles')
        require(isinstance(entries, list) and len(entries) <= 256, 'Invalid profile store.')
        ids = set()
        for entry in entries:
            require(isinstance(entry, dict) and integer(entry.get('revision'), 1))
            profile = validate_profile(entry.get('profile'))
            require(profile['id'] not in ids, 'Duplicate saved profile.')
            ids.add(profile['id'])
            if 'cloudSource' in entry:
                source = entry['cloudSource']
                require(isinstance(source, dict))
                require(profile['id'] == cloud_id(source, {**profile, 'id': source.get('profileId')}))
                require(entry['revision'] == 1)
        active = store.get('active')
        if active is not None:
            require(isinstance(active, dict) and integer(active.get('revision'), 1)
                    and integer(active.get('profileRevision'), 1))
            validate_profile(active.get('profile'))
        for profile in self.builtins:
            if profile['id'] not in ids and len(entries) < 256:
                entries.append(dict(revision=1, profile=deepcopy(profile)))
        return store

    @contextmanager
    def transaction(self):
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        lock = self.directory / 'write.lock'
        deadline = monotonic() + 3
        while True:
            try:
                lock.mkdir(mode=0o700)
                break
            except FileExistsError:
                if monotonic() >= deadline:
                    raise ProfileError('Profiles are busy. Try again shortly.')
                time.sleep(0.025)
        try:
            store = self.read()
            yield store
            require(len(encoded(store)) <= 8 * 1024 * 1024, 'Profile store exceeds 8 MiB.')
            atomic_json(self.directory / 'store.json', store)
        finally:
            lock.rmdir()

    def summary(self, store=None):
        store = self.read() if store is None else store
        active = store.get('active')
        result = dict(profiles=[dict(id=entry['profile']['id'], name=entry['profile']['name'], revision=entry['revision'])
                                for entry in store['profiles']],
                      activationRevision=active['revision'] if active else 0,
                      cloudAdoptionSupported=True, agentCheckSupported=True)
        check = store.get('agentConnection')
        if isinstance(check, dict) and matches(check.get('code'), r'[a-f0-9]{12}') and number(check.get('checkedAt')):
            age = time.time() - check['checkedAt'] / 1000
            if 0 <= age <= 600:
                result['agentConnection'] = dict(code=check['code'], ageSeconds=age)
        sync = store.get('consolePortSync')
        if isinstance(sync, dict):
            character = sync.get('character')
            if (slug(sync.get('profileId')) and isinstance(character, dict) and text(character.get('name'))
                    and not any(ord(c) < 32 or ord(c) == 127 for c in character['name'])
                    and finite(sync.get('exportedAt'), 1, MAX_REVISION)):
                public = dict(profileId=sync['profileId'], characterName=character['name'],
                              exportedAt=sync['exportedAt'], following=bool(active and active['profile']['id'] == sync['profileId']))
                for key, valid in (('buttonCount', integer(sync.get('buttonCount'), 1, 17)),
                                   ('actionPage', integer(sync.get('actionPage'), 0, 100)),
                                   ('consolePortVersion', isinstance(sync.get('consolePortVersion'), str)
                                    and len(sync['consolePortVersion'].encode()) <= 80)):
                    if valid:
                        public[key] = sync[key]
                mods = sync.get('modifiers')
                if only(mods, ('shift', 'ctrl', 'alt')) and all(
                        isinstance(value, str) and value in BUTTONS | TRIGGERS | {'none'} for value in mods.values()):
                    public['modifiers'] = mods
                result['consolePortSync'] = public
        return result

    @staticmethod
    def expect(store, expected):
        require(integer(expected), 'Invalid activation revision.')
        previous = (store.get('active') or {}).get('revision', 0)
        require(previous == expected and previous < MAX_REVISION, 'Profiles changed. Refresh the list and try again.')
        return previous

    def select(self, profile_id, revision, expected):
        require(slug(profile_id) and integer(revision, 1))
        with self.transaction() as store:
            previous = self.expect(store, expected)
            entry = next((item for item in store['profiles'] if item['profile']['id'] == profile_id), None)
            require(entry is not None and entry['revision'] == revision, 'Profiles changed. Refresh the list and try again.')
            store['active'] = dict(revision=previous + 1, profileRevision=revision, profile=deepcopy(entry['profile']))
        return self.summary(store), store['active']

    def adopt(self, profile, source, expected):
        profile = validate_profile(profile)
        local_id = cloud_id(source, profile)
        local = {**profile, 'id': local_id}
        with self.transaction() as store:
            previous = self.expect(store, expected)
            entry = next((item for item in store['profiles'] if item['profile']['id'] == local_id), None)
            if entry is not None:
                require(entry['revision'] == 1 and entry['profile'] == local and entry.get('cloudSource') == source,
                        'This cloud revision has different saved content. Refresh and try again.')
            else:
                require(len(store['profiles']) < 256, 'Profile limit reached.')
                store['profiles'].append(dict(revision=1, profile=local, cloudSource=deepcopy(source)))
            active = store.get('active')
            same = active and active['profile'] == local and active['profileRevision'] == 1
            store['active'] = dict(revision=previous if same else previous + 1, profileRevision=1, profile=local)
        summary = self.summary(store)
        summary['adoption'] = dict(profileId=local_id, profileRevision=1, source=deepcopy(source))
        return summary, store['active']

    def save_phone(self, profile, expected, expected_profile):
        profile = validate_profile(profile)
        require(matches(profile['id'], r'phone-[a-f0-9]{32}') and integer(expected_profile))
        with self.transaction() as store:
            previous = self.expect(store, expected)
            entry = next((e for e in store['profiles'] if e['profile']['id'] == profile['id']), None)
            if entry:
                unchanged = entry['profile'] == profile
                require(entry.get('phoneEdited') is True and not entry.get('cloudSource'), 'Save your own phone controller copy.')
                require((entry['revision'] == expected_profile or unchanged) and entry['revision'] < MAX_REVISION,
                        'This controller changed elsewhere. Refresh and try again.')
                if not unchanged:
                    entry['profile'] = deepcopy(profile); entry['revision'] += 1
            else:
                require(expected_profile == 0 and len(store['profiles']) < 256)
                entry = dict(profile=deepcopy(profile), revision=1, phoneEdited=True)
                store['profiles'].append(entry)
            active = store.get('active')
            same = active and active['profile']['id'] == profile['id'] and active['profileRevision'] == entry['revision']
            store['active'] = dict(revision=previous if same else previous+1, profileRevision=entry['revision'], profile=deepcopy(profile))
        return self.summary(store), store['active']

    def write_status(self, status):
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        atomic_json(self.directory / 'receiver-status.json', status)
