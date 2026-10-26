"""Read saved addon snapshots as data. Never execute Lua or write game files."""
from copy import deepcopy
import hashlib
from pathlib import Path
import re
import time

from .profiles import (MODIFIERS, ProfileError, bounded_read, finite, integer,
                       load_json, matches, require, text, validate_profile)
from .artwork import IconLookup

KEY_MAP = dict(zip(('PAD1 PAD2 PAD3 PAD4 PADLSHOULDER PADRSHOULDER PADLTRIGGER PADRTRIGGER '
                   'PADBACK PADFORWARD PADLSTICK PADRSTICK PADDUP PADDDOWN PADDLEFT PADDRIGHT PADSYSTEM').split(),
                  'a b x y lb rb lt rt back start ls rs up down left right guide'.split()))
MODIFIER_CVARS = dict(shift='GamePadEmulateShift', ctrl='GamePadEmulateCtrl', alt='GamePadEmulateAlt')
UTILITY_ICONS = dict(JUMP='cp_jump', INTERACTTARGET='cp_interact', TARGETNEARESTENEMY='cp_target',
                     TARGETPREVIOUSENEMY='cp_target', TARGETSCANENEMY='cp_target',
                     TARGETNEARESTFRIEND='cp_interact', TARGETPREVIOUSFRIEND='cp_interact',
                     OPENALLBAGS='cp_bags', TOGGLEWORLDMAP='cp_map', TOGGLEGAMEMENU='cp_menu')
UTILITY_ICONS['CLICK ConsolePortQuickMenu:LeftButton'] = 'cp_menu'
UTILITY_LABELS = {'CLICK ConsolePortQuickMenu:LeftButton': 'Quick menu',
                  'CLICK ConsolePortUtilityToggle:LeftButton': 'Utility ring'}


def decode_saved(data):
    require(len(data) <= 4 * 1024 * 1024, 'ConsolePort snapshot file is too large.')
    source = data.decode('utf-8')
    require(re.match(r'^\s*ThumbleBridgeDB\s*=\s*\{', source), 'Invalid addon saved variables.')
    match = re.search(r'\["syncText"\]\s*=\s*"', source)
    require(match is not None, 'No ConsolePort sync snapshot in this file.')
    source = source[match.end():].encode('utf-8')
    output, index = bytearray(), 0
    escapes = dict(zip(b'abfnrtv\\"\'', (7, 8, 12, 10, 13, 9, 11, 92, 34, 39)))
    while index < len(source):
        byte = source[index]
        index += 1
        if byte == 34:
            require(len(output) <= 262144)
            return bytes(output)
        require(byte not in (10, 13) and len(output) < 262144, 'Invalid Lua string.')
        if byte != 92:
            output.append(byte)
            continue
        require(index < len(source), 'Unterminated Lua escape.')
        escape = source[index]
        index += 1
        if 48 <= escape <= 57:
            value, count = escape - 48, 1
            while count < 3 and index < len(source) and 48 <= source[index] <= 57:
                value = value * 10 + source[index] - 48
                index, count = index + 1, count + 1
            require(value <= 255, 'Invalid Lua decimal escape.')
            output.append(value)
        else:
            require(escape in escapes, 'Unsupported Lua escape.')
            output.append(escapes[escape])
    raise ProfileError('Unterminated Lua string.')


def validate_snapshot(data, now=None):
    require(len(data) <= 262144, 'ConsolePort snapshot is too large.')
    value = load_json(data)
    require(isinstance(value, dict) and integer(value.get('bridgeVersion'), 1, 1)
            and value.get('kind') == 'consoleport-sync')
    require(finite(value.get('exportedAt'), 1, 9_007_199_254_740_991))
    require(abs((time.time() if now is None else now) - value['exportedAt']) <= 300,
            'Reload WoW to save a fresh ConsolePort snapshot.')
    character = value.get('character')
    require(isinstance(character, dict) and text(character.get('name'))
            and not any(ord(c) < 32 or ord(c) == 127 for c in character['name'])
            and matches(character.get('guid'), r'[A-Za-z0-9-]{1,128}'))
    mods = value.get('modifiers')
    require(isinstance(mods, dict))
    for key in MODIFIER_CVARS.values():
        output = mods.get(key)
        require(isinstance(output, str) and (output.upper() == 'NONE' or output in KEY_MAP))
    buttons = value.get('consolePortLayout')
    require(isinstance(buttons, list) and 1 <= len(buttons) <= 17)
    seen = set()
    for button in buttons:
        require(isinstance(button, dict) and isinstance(button.get('key'), str))
        key, layers = button['key'], button.get('layers')
        require(key in KEY_MAP and key not in seen)
        seen.add(key)
        require(isinstance(layers, list) and len(layers) == 8)
        states = set()
        for layer in layers:
            require(isinstance(layer, dict))
            state, label, command = layer.get('modifier'), layer.get('label'), layer.get('command')
            require(isinstance(state, str) and state in MODIFIERS and state not in states)
            states.add(state)
            require(isinstance(label, str) and 0 < len(label.encode()) <= 512 and '|' not in label)
            require(isinstance(command, str) and len(command.encode()) <= 512)
            require(not any(ord(c) < 32 or ord(c) == 127 for c in label + command))
            if 'kind' in layer:
                require(layer['kind'] in ('spell', 'item') and integer(layer.get('id'), 1, 2147483647))
    return value


def short_label(value):
    # Do not cut a UTF-16 surrogate pair when trimming a label for the phone.
    result, units = '', 0
    for character in value:
        width = len(character.encode('utf-16-le')) // 2
        if units + width > 80:
            break
        result, units = result + character, units + width
    return result or 'Unbound'


def make_profile(snapshot, source, lookup=None):
    profile = validate_profile(source)
    require(profile.get('theme') == 'consoleport', 'Select a ConsolePort controller to enable automatic sync.')
    guid = snapshot['character']['guid']
    profile['id'] = 'consoleport-' + hashlib.sha256(guid.encode()).hexdigest()[:24]
    profile['name'] = short_label(snapshot['character']['name'] + ' · ConsolePort')
    by_output = {KEY_MAP[button['key']]: button for button in snapshot['consolePortLayout']}
    mappings = {mapping['controlId']: mapping['outputs'][0] for mapping in profile['mappings']}
    for control in profile['controls']:
        if control['type'] == 'stick':
            continue
        output = mappings[control['id']]
        previous_layers = control.pop('layers', None)
        control.pop('icon', None)
        button = by_output.get(output)
        if button is None:
            if previous_layers is not None:
                control['label'] = control.get('badge', output.upper())
            continue
        layers = {}
        for layer in button['layers']:
            command = layer['command']
            empty = 'kind' not in layer and re.fullmatch(r'(?:ACTIONBUTTON[0-9]+|MULTIACTIONBAR[0-9]+BUTTON[0-9]+)', command)
            label = 'Unbound' if empty else UTILITY_LABELS.get(command, layer['label'])
            display = dict(label=short_label(label))
            icon = UTILITY_ICONS.get(command)
            # Embedded fallback; the port never needs network access to sync labels.
            if layer.get('kind') == 'spell' and layer.get('id') == 6603:
                icon = 'ability_meleedamage'
            elif lookup and layer.get('kind') in ('spell', 'item'):
                icon = lookup(layer['kind'], layer['id']) or icon
            if label != 'Unbound' and icon:
                display['icon'] = icon
            layers[layer['modifier']] = display
        control.update(label=layers['']['label'], layers=layers)
        if 'icon' in layers['']:
            control['icon'] = layers['']['icon']
    profile['modifiers'] = {key: KEY_MAP.get(snapshot['modifiers'][cvar], 'none')
                            for key, cvar in MODIFIER_CVARS.items()}
    return validate_profile(profile)


def commit(store, profile, snapshot, source_path, expected):
    profile = validate_profile(profile)
    with store.transaction() as data:
        previous = store.expect(data, expected)
        active = data.get('active')
        if not active or active['profile'] != profile:
            entry = next((entry for entry in data['profiles'] if entry['profile']['id'] == profile['id']), None)
            revision = (entry['revision'] if entry else 0) + 1
            require(integer(revision, 1) and (entry or len(data['profiles']) < 256))
            updated = dict(revision=revision, profile=profile)
            if entry:
                data['profiles'][data['profiles'].index(entry)] = updated
            else:
                data['profiles'].append(updated)
            data['active'] = dict(revision=previous + 1, profileRevision=revision, profile=profile)
        provenance = dict(sourcePath=str(source_path), exportedAt=snapshot['exportedAt'],
                          character=deepcopy(snapshot['character']), profileId=profile['id'],
                          modifiers=profile['modifiers'], buttonCount=len(snapshot['consolePortLayout']))
        if isinstance(snapshot.get('consolePortVersion'), str) and len(snapshot['consolePortVersion'].encode()) <= 80:
            provenance['consolePortVersion'] = snapshot['consolePortVersion']
        if integer(snapshot.get('actionPage'), 0, 100):
            provenance['actionPage'] = snapshot['actionPage']
        data['consolePortSync'] = provenance
    return data['active']


def snapshot_files(roots):
    result, budget = [], 4096

    def directories(path):
        nonlocal budget
        children = []
        try:
            for child in path.iterdir():
                budget -= 1
                if budget < 0 or len(children) >= 512:
                    break
                if (not child.name.startswith('.') and child.is_dir() and not child.is_symlink()
                        and not (hasattr(child, 'is_junction') and child.is_junction())):
                    children.append(child)
        except OSError:
            pass
        return children

    for root in roots[:8]:
        root = Path(root).resolve()
        clients = [root] if (root / 'WTF/Account').is_dir() else [path for path in directories(root) if path.name.startswith('_')]
        for client in clients:
            account_root = client / 'WTF/Account'
            if not account_root.resolve().is_relative_to(root):
                continue
            for account in directories(account_root):
                for realm in directories(account):
                    if realm.name == 'SavedVariables':
                        continue
                    for character in directories(realm):
                        file = character / 'SavedVariables/ThumbleBridge.lua'
                        if (file.is_file() and not file.is_symlink()
                                and file.resolve().is_relative_to(account_root.resolve())):
                            result.append(file.resolve())
                            if len(result) >= 512:
                                return result
    return result


class ConsolePortSync:
    def __init__(self, store, roots=(), wall=time.time, lookup=None):
        self.store, self.roots, self.wall = store, list(roots), wall
        self.stamps = {}
        self.pending = None
        self.lookup = lookup if lookup is not None else IconLookup()
        self.detail = 'ConsolePort: waiting for /reload' if roots else 'ConsolePort: choose your WoW folder with --wow-dir'

    def poll(self, baseline=False):
        files = snapshot_files(self.roots)
        newest = None
        stamps = {}
        for file in files:
            try:
                stat = file.stat()
                stamp = (stat.st_mtime_ns, stat.st_size)
                stamps[str(file)] = stamp
                if baseline or self.stamps.get(str(file)) == stamp:
                    continue
                data = decode_saved(bounded_read(file, 4 * 1024 * 1024))
                snapshot = validate_snapshot(data, self.wall())
                if newest is None or stat.st_mtime_ns > newest[0]:
                    newest = (stat.st_mtime_ns, file, data, snapshot)
            except (OSError, ValueError, KeyError, TypeError) as error:
                self.detail = ('ConsolePort: could not read the snapshot; check folder permissions.'
                               if isinstance(error, OSError) else 'ConsolePort: ' + str(error))
        self.stamps = stamps
        if newest:
            self.pending = newest
        if self.pending:
            _, file, data, snapshot = self.pending
            try:
                # Pending retries must still be recent and must still match disk.
                snapshot = validate_snapshot(data, self.wall())
                store = self.store.read()
                active = store.get('active')
                source = active['profile'] if active else next(
                    entry['profile'] for entry in store['profiles'] if entry['profile']['id'] == 'consoleport-standard')
                if hasattr(self.lookup, 'begin'):
                    self.lookup.begin()
                profile = make_profile(snapshot, source, self.lookup)
                require(decode_saved(bounded_read(file, 4 * 1024 * 1024)) == data,
                        'Snapshot changed during sync. Reload WoW to retry.')
                commit(self.store, profile, snapshot, file, active['revision'] if active else 0)
                self.pending = None
                self.detail = f"ConsolePort: {snapshot['character']['name']} synced after reload"
            except (OSError, ValueError, KeyError, TypeError, StopIteration) as error:
                # Only a busy writer is transient; stale/unsupported/changed
                # snapshots need another explicit reload, not a delayed activation.
                if not isinstance(error, ProfileError) or 'Profiles are busy' not in str(error):
                    self.pending = None
                self.detail = ('ConsolePort: could not read the snapshot; check folder permissions.'
                               if isinstance(error, OSError) else 'ConsolePort: ' + str(error))
        return self.detail
