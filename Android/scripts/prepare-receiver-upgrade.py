#!/usr/bin/env python3
"""Explicit, offline v2-state rebuild for a user-requested receiver upgrade.
Not used by host decoding/import. Only existing declared UUIDs are retained; no
slot aliases or UUID inference is added to the receiver. Original state must be
backed up by the caller. Refuses overwrite and ambiguous declarations.
"""
import argparse
import copy
import json
import os
import time
import uuid

VARIANTS = ('customization', 'landscapeCustomization', 'portraitCustomization')
ROUTING = ('button', 'mappedButton', 'builtInButton', 'legacySlot', 'inputID', 'defaultControlID')
DIRECTIONS = ('up', 'down', 'left', 'right')


def pairs(value):
    if isinstance(value, dict):
        return dict(value)
    assert isinstance(value, list) and len(value) % 2 == 0, 'Malformed Swift map'
    result = dict(zip(value[::2], value[1::2]))
    assert len(result) * 2 == len(value), 'Duplicate map entries'
    return result


def uid(raw):
    assert isinstance(raw, str) and len(raw) == 36
    return str(uuid.UUID(raw)).upper()


def prepare(original):
    assert original['schemaVersion'] == 2, 'Only explicit schema-v2 upgrades are supported'
    state = copy.deepcopy(original)
    reports = []
    maps = {}
    for profile in state['profiles']:
        pid = profile['id']
        old = next(p for p in original['profiles'] if p['id'] == pid)
        variants = [old[v] for v in VARIANTS if isinstance(old.get(v), dict)]
        elements = [e for c in variants for e in c['elements']]
        for c in variants:
            assert len({uid(e['id']) for e in c['elements']}) == len(c['elements']), 'Duplicate element UUID'
        by_id = {}
        for element in elements:
            by_id.setdefault(uid(element['id']), []).append(element)
        def profile_map(field):
            return next((v for k, v in original.get(field, {}).items() if k.lower() == pid.lower()), {})
        def slot_output(slot):
            if slot is None:
                return {}
            for table, keyboard in [(profile_map('profileOutputBindings'), False),
                                    (profile_map('profileKeyBindings'), True),
                                    (original.get('outputBindings', {}), False),
                                    (original.get('keyBindings', {}), True)]:
                if slot in table:
                    return copy.deepcopy({'keyboard': table[slot], 'gamepadButtons': []} if keyboard else table[slot])
            return {}
        def resolve(candidates, part='primary'):
            builtin = candidates[0].get('builtInButton')
            if part == 'primary' and builtin is not None:
                return slot_output(builtin)
            for e in candidates:
                direct = e.get('output') if part == 'primary' else pairs(e.get('partOutputs', {})).get(part)
                if direct is not None:
                    return copy.deepcopy(direct)
            for e in candidates:
                slot = e.get('legacySlot') if part in ('primary', 'trigger_digital') else e.get('joystickMapping', {}).get(part.removeprefix('joystick_'))
                if slot is not None:
                    return slot_output(slot)
            return {}
        primary = {eid: resolve(candidates) for eid, candidates in by_id.items()}
        maps[pid] = primary
        orphan_design_references = 0
        for variant in VARIANTS:
            layout = profile.get(variant)
            if not isinstance(layout, dict):
                continue
            old_layout = old[variant]
            builtins = {e['builtInButton']: uid(e['id']) for e in old_layout['elements'] if e.get('builtInButton')}
            assert len(builtins) == sum(bool(e.get('builtInButton')) for e in old_layout['elements']), 'Ambiguous built-in slot'
            for field in ('buttonCustomizations', 'labelOverrides'):
                if field in layout:
                    layout[field] = [item for key, value in pairs(layout[field]).items() if key in builtins
                                     for item in (builtins[key], value)]
            canonical = {}
            for e in layout['elements']:
                eid = uid(e['id'])
                e['output'] = copy.deepcopy(primary[eid])
                if 'defaultOutput' not in e:
                    e['defaultOutput'] = copy.deepcopy(primary[eid])
                if e.get('kind') == 'joystick':
                    owned = {direction: resolve(by_id[eid], 'joystick_' + direction) for direction in DIRECTIONS}
                    e['joystickMapping'] = owned
                    e['partOutputs'] = [item for direction in DIRECTIONS for item in ('joystick_' + direction, owned[direction])]
                elif e.get('kind') == 'trigger':
                    part_map = pairs(e.get('partOutputs', {}))
                    part_map['trigger_digital'] = resolve(by_id[eid], 'trigger_digital')
                    e['partOutputs'] = [item for pair in part_map.items() for item in pair]
                for key in ROUTING:
                    e.pop(key, None)
                canonical[eid] = e
            for mirror in layout.get('customButtons', []):
                eid = uid(mirror['id'])
                assert eid in canonical, 'Custom mirror has no declared UUID'
                for key in ROUTING:
                    mirror.pop(key, None)
                for field in ('joystickMapping', 'partOutputs', 'output', 'defaultOutput'):
                    if field in canonical[eid]:
                        mirror[field] = copy.deepcopy(canonical[eid][field])
            def identity(value):
                if value.get('kind') != 'builtin':
                    return value
                eid = builtins.get(value.get('button'))
                nonlocal orphan_design_references
                if eid is None:
                    orphan_design_references += 1
                    return None
                preset = canonical[eid].get('kind') == 'button' and uuid.UUID(eid).int in range(0x101, 0x10B)
                return {'kind': 'builtin' if preset else 'custom', 'button' if preset else 'id': eid}
            metadata = layout.get('designMetadata', {})
            if 'layerOrder' in metadata:
                metadata['layerOrder'] = [mapped for v in metadata['layerOrder'] if (mapped := identity(v)) is not None]
            for group in metadata.get('groups', []):
                group['children'] = [mapped for v in group['children'] if (mapped := identity(v)) is not None]
            # Existing element order, UUIDs, layouts, labels and unknown visual fields survive.
            assert [e['id'] for e in layout['elements']] == [e['id'] for e in old_layout['elements']]
            assert [e.get('layout') for e in layout['elements']] == [e.get('layout') for e in old_layout['elements']]
        reports.append({'id': pid, 'name': profile['name'], 'declaredUUIDs': len(by_id), 'orientationVariants': len(variants), 'staleDesignReferencesRemoved': orphan_design_references})
    state['profileOutputBindings'] = maps
    state['profileKeyBindings'] = {pid: {eid: out['keyboard'] for eid, out in outputs.items() if out.get('keyboard') is not None} for pid, outputs in maps.items()}
    active_id = next(pid for pid in maps if pid.lower() == state['activeProfileID'].lower())
    state['outputBindings'] = copy.deepcopy(maps[active_id])
    state['keyBindings'] = copy.deepcopy(state['profileKeyBindings'][active_id])
    state['schemaVersion'] = 3
    state['configurationRevision'] += 1
    state['configurationUpdatedAt'] = int(time.time() * 1000)
    state['recentConfigurationCommits'] = []  # Old request digests belong to the old schema; backup retains their audit history.
    for key in ('serverID', 'trustedClients', 'activeProfileID', 'defaultProfileID'):
        assert state[key] == original[key], 'Authority/selection changed'
    return state, reports


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    with open(args.source) as source:
        original = json.load(source)
    result, report = prepare(original)
    fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as output:
        json.dump(result, output, sort_keys=True, separators=(',', ':'))
        output.flush()
        os.fsync(output.fileno())
    print(json.dumps({'profiles': report, 'sourceSchema': 2, 'targetSchema': 3, 'selectionAndServerIdentityPreserved': True}))
