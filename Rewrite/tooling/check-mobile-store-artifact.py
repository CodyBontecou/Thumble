#!/usr/bin/env python3
"""Bounded read-only store artifact metadata inspection; never signing/store acceptance."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import struct
import sys
import zipfile
import zlib

MAX_FILE = 268_435_456
MAX_TOTAL = 2_147_483_648
MAX_ENTRIES = 20_000
MAX_METADATA = 2_097_152
ANDROID = 'http://schemas.android.com/apk/res/android'
REASONS = {'NSPrivacyAccessedAPICategoryUserDefaults': 'CA92.1',
           'NSPrivacyAccessedAPICategorySystemBootTime': '35F9.1'}


class Invalid(ValueError):
    pass


def require(value):
    if not value:
        raise Invalid('store_artifact_invalid_or_unsupported')


def name(value):
    require(isinstance(value, str) and 0 < len(value.encode('utf8')) <= 1024 and
            '\\' not in value and '\x00' not in value and not value.startswith('/') and
            all(p not in ('', '.', '..') for p in value.split('/')))
    return value


def open_absolute(path, directory=False):
    path = Path(path)
    require(path.is_absolute() and '..' not in path.parts and path != Path('/'))
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for index, part in enumerate(path.parts[1:]):
            flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
            if directory or index < len(path.parts) - 2:
                flags |= os.O_DIRECTORY
            next_fd = os.open(part, flags, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        return fd
    except BaseException:
        os.close(fd)
        raise


def metadata_candidate(path):
    return path.endswith(('.plist', '.xcprivacy', 'AndroidManifest.xml')) or notice(path)


def notice(path):
    leaf = PurePosixPath(path).name.lower()
    return ('notice' in leaf or 'license' in leaf or 'acknowledgement' in leaf) and leaf.endswith(('.txt', '.plist', '.html', '.json', '.md'))


class Inventory:
    def __init__(self):
        self.hashes, self.metadata, self.total = {}, {}, 0
        self.entries, self.metadata_bytes, self.artifact_sha256 = 0, 0, None
        self.folded = set()
        self.entry_paths = set()

    def add(self, path, size, digest, data=None):
        name(path)
        require(path.casefold() not in self.folded and len(self.hashes) < MAX_ENTRIES)
        self.total += size
        require(size <= MAX_FILE and self.total <= MAX_TOTAL)
        self.folded.add(path.casefold())
        self.hashes[path] = digest
        if data is not None:
            self.metadata_bytes += len(data)
            require(len(data) <= MAX_METADATA and self.metadata_bytes <= 33_554_432)
            self.metadata[path] = data

    def summary(self):
        digest = hashlib.sha256()
        for path in sorted(self.hashes):
            digest.update(path.encode() + b'\0' + self.hashes[path].encode() + b'\n')
        return {'files': len(self.hashes), 'bytes': self.total, 'treeSHA256': digest.hexdigest(), 'artifactSHA256': self.artifact_sha256}


def directory_inventory(path):
    inventory = Inventory()
    root = open_absolute(path, True)

    def scan(fd, prefix='', depth=0):
        require(depth <= 32)
        before = os.fstat(fd)
        entries = os.listdir(fd)
        inventory.entries += len(entries)
        require(inventory.entries <= MAX_ENTRIES)
        require(len(entries) <= MAX_ENTRIES)
        for entry in sorted(entries):
            relative = name(prefix + entry)
            require(relative.casefold() not in inventory.entry_paths)
            inventory.entry_paths.add(relative.casefold())
            info = os.stat(entry, dir_fd=fd, follow_symlinks=False)
            require(stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode))
            child = os.open(entry, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK |
                            (os.O_DIRECTORY if stat.S_ISDIR(info.st_mode) else 0), dir_fd=fd)
            try:
                opened = os.fstat(child)
                require((info.st_dev, info.st_ino) == (opened.st_dev, opened.st_ino))
                if stat.S_ISDIR(info.st_mode):
                    scan(child, relative + '/', depth + 1)
                else:
                    require(info.st_size <= MAX_FILE and info.st_nlink == 1 and inventory.total + info.st_size <= MAX_TOTAL)
                    digest, data, count = hashlib.sha256(), [], 0
                    while True:
                        block = os.read(child, 65536)
                        if not block:
                            break
                        count += len(block)
                        require(count <= MAX_FILE)
                        digest.update(block)
                        if metadata_candidate(relative):
                            require(count <= MAX_METADATA)
                            data.append(block)
                    final = os.fstat(child)
                    require(count == info.st_size and (info.st_mtime_ns, info.st_ctime_ns) == (final.st_mtime_ns, final.st_ctime_ns))
                    inventory.add(relative, count, digest.hexdigest(), b''.join(data) if metadata_candidate(relative) else None)
            finally:
                os.close(child)
        require((before.st_mtime_ns, before.st_ctime_ns) == (os.fstat(fd).st_mtime_ns, os.fstat(fd).st_ctime_ns))
    try:
        scan(root)
    finally:
        os.close(root)
    return inventory


def bundle_inventory(path):
    fd = open_absolute(path)
    inventory = Inventory()
    with os.fdopen(fd, 'rb') as source:
        info = os.fstat(source.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_size <= 536_870_912)
        # Reject ZIP64/multi-disk and excessive central-directory counts before ZipFile allocates entries.
        source.seek(max(0, info.st_size - 65557))
        tail = source.read(65557)
        at = tail.rfind(b'PK\x05\x06')
        require(at >= 0 and len(tail) >= at + 22 and (at < 20 or tail[at - 20:at - 16] != b'PK\x06\x07'))
        _, disk, central_disk, disk_count, count, central_size, central_offset, comment = struct.unpack('<4s4H2LH', tail[at:at + 22])
        require(disk == central_disk == 0 and disk_count == count and 0 < count <= MAX_ENTRIES and
                len(tail) == at + 22 + comment and central_size <= 16_777_216 and
                central_offset + central_size <= info.st_size)
        source.seek(0)
        digest = hashlib.sha256()
        while True:
            block = source.read(65536)
            if not block:
                break
            digest.update(block)
        inventory.artifact_sha256 = digest.hexdigest()
        source.seek(0)
        with zipfile.ZipFile(source) as archive:
            require(len(archive.infolist()) == count)
            paths = set()
            for entry in archive.infolist():
                require(entry.orig_filename == entry.filename)
                relative = name(entry.filename[:-1] if entry.is_dir() else entry.filename)
                require(relative.casefold() not in paths)
                paths.add(relative.casefold())
                inventory.entry_paths.add(relative.casefold())
                mode = entry.external_attr >> 16
                require(not (mode and stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR)) and
                        not entry.flag_bits & 1 and entry.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED) and
                        entry.file_size <= MAX_FILE and entry.file_size <= max(1, entry.compress_size) * 200)
                if entry.is_dir():
                    require(entry.file_size == 0)
                    continue
                require(inventory.total + entry.file_size <= MAX_TOTAL)
                digest, data, size = hashlib.sha256(), [], 0
                with archive.open(entry) as stream:
                    while True:
                        block = stream.read(65536)
                        if not block:
                            break
                        size += len(block)
                        require(size <= entry.file_size)
                        digest.update(block)
                        if metadata_candidate(relative):
                            require(size <= MAX_METADATA)
                            data.append(block)
                require(size == entry.file_size)
                inventory.add(relative, size, digest.hexdigest(), b''.join(data) if metadata_candidate(relative) else None)
            for path in inventory.hashes:
                require(all('/'.join(path.split('/')[:i]).casefold() not in inventory.folded for i in range(1, len(path.split('/')))))
        final = os.fstat(source.fileno())
        require((info.st_size, info.st_mtime_ns, info.st_ctime_ns) == (final.st_size, final.st_mtime_ns, final.st_ctime_ns))
    return inventory


# AAPT2 Resources.proto XmlNode/XmlElement/XmlAttribute scalar subset.
# No generated or vendored implementation; unsupported critical values fail closed.
def varint(data, offset):
    value = 0
    for shift in range(0, 70, 7):
        require(offset < len(data))
        byte = data[offset]
        offset += 1
        require(shift < 63 or byte <= 1)
        value |= (byte & 127) << shift
        if byte < 128:
            require(shift == 0 or byte != 0)
            return value, offset
    raise Invalid()


def fields(data):
    offset, result = 0, {}
    require(len(data) <= MAX_METADATA)
    while offset < len(data):
        key, offset = varint(data, offset)
        field, wire = key >> 3, key & 7
        require(field > 0 and wire in (0, 1, 2, 5))
        if wire == 0:
            value, offset = varint(data, offset)
        else:
            size = {1: 8, 5: 4}.get(wire)
            if wire == 2:
                size, offset = varint(data, offset)
            require(size is not None and offset + size <= len(data))
            value = data[offset:offset + size]
            offset += size
        result.setdefault(field, []).append((wire, value))
        require(sum(map(len, result.values())) <= 8192)
    return result


def single(f, key, wire=2, default=None):
    if key not in f:
        return default
    require(len(f[key]) == 1 and f[key][0][0] == wire)
    return f[key][0][1]


def text(data):
    require(isinstance(data, bytes) and len(data) <= 8192)
    value = data.decode('utf8')
    require('\x00' not in value)
    return value


def compiled(data):
    item = fields(data)
    kinds = [key for key in range(1, 8) if key in item]
    require(len(kinds) == 1)
    key = kinds[0]
    value = single(item, key)
    if key in (2, 3):
        return text(single(fields(value), 1, default=b''))
    if key == 7:
        primitive = fields(value)
        require(len(primitive) == 1)
        kind = next(iter(primitive))
        if kind in (6, 7, 8):
            scalar = single(primitive, kind, 0)
            if kind == 8:
                require(scalar in (0, 1))
                return 'true' if scalar else 'false'
            return str(scalar)
    return None


def manifest_node(data, budget=None, depth=0):
    if budget is None:
        budget = [4096]
    budget[0] -= 1
    require(budget[0] >= 0 and depth <= 32)
    node = fields(data)
    require(not (1 in node and 2 in node))
    element = single(node, 1)
    if element is None:
        text(single(node, 2, default=b''))
        return None
    f = fields(element)
    tag = text(single(f, 3, default=b''))
    namespace = text(single(f, 2, default=b''))
    require(tag and len(tag) <= 128)
    attributes = {}
    for wire, raw in f.get(4, []):
        require(wire == 2)
        attr = fields(raw)
        ns = text(single(attr, 1, default=b''))
        key = text(single(attr, 2, default=b''))
        require(key and (ns, key) not in attributes)
        raw_value = text(single(attr, 3, default=b''))
        value = compiled(single(attr, 6)) if 6 in attr else raw_value
        attributes[(ns, key)] = value
    children = []
    for wire, raw in f.get(5, []):
        require(wire == 2)
        child = manifest_node(raw, budget, depth + 1)
        if child is not None:
            children.append(child)
    return {'tag': tag, 'namespace': namespace, 'attrs': attributes, 'children': children}


def attribute(node, key, namespace=ANDROID, default=None):
    value = node['attrs'].get((namespace, key), default)
    require(value is not None)
    return value


class UniquePlistDict(dict):
    def __init__(self, pairs=()):
        super().__init__()
        for key, value in pairs:
            self[key] = value

    def __setitem__(self, key, value):
        require(key not in self)
        super().__setitem__(key, value)


def plist(data):
    return plistlib.loads(data, dict_type=UniquePlistDict)


def privacy_ok(data):
    value = plist(data)
    require(isinstance(value, dict))
    entries = value.get('NSPrivacyAccessedAPITypes', [])
    require(isinstance(entries, list) and all(isinstance(v, dict) for v in entries))
    require(all(isinstance(v.get('NSPrivacyAccessedAPIType'), str) and isinstance(v.get('NSPrivacyAccessedAPITypeReasons'), list) and all(isinstance(r, str) for r in v['NSPrivacyAccessedAPITypeReasons']) for v in entries))
    categories = [v.get('NSPrivacyAccessedAPIType') for v in entries]
    require(len(categories) == len(set(categories)))
    return value.get('NSPrivacyTracking') is False and all(any(v.get('NSPrivacyAccessedAPIType') == category and reason in v.get('NSPrivacyAccessedAPITypeReasons', []) for v in entries) for category, reason in REASONS.items())


def audit(path, platform, version, build):
    inventory = directory_inventory(path) if platform == 'ios' else bundle_inventory(path)
    checks, selected = {}, {}
    paths = inventory.hashes
    if platform == 'ios':
        apps = [p for p in paths if re.fullmatch(r'Products/Applications/[^/]+\.app/Info\.plist', p)]
        require(len(apps) == 1 and 'Info.plist' in inventory.metadata)
        app = apps[0][:-len('Info.plist')]
        info = plist(inventory.metadata[apps[0]])
        archive = plist(inventory.metadata['Info.plist'])
        require(isinstance(info, dict) and isinstance(archive, dict))
        checks['archive_application_path'] = archive.get('ApplicationProperties', {}).get('ApplicationPath') == app[len('Products/'):].rstrip('/')
        executable = info.get('CFBundleExecutable')
        checks['executable_present'] = isinstance(executable, str) and bool(executable) and '/' not in executable and app + executable in paths
        checks['identity'] = info.get('CFBundleIdentifier') == 'com.codybontecou.PocketPad.iOS'
        checks['version'] = info.get('CFBundleShortVersionString') == version and info.get('CFBundleVersion') == build
        checks['iphone_only'] = info.get('UIDeviceFamily') == [1]
        checks['minimum_os_declared'] = isinstance(info.get('MinimumOSVersion'), str) and bool(re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,2}', info['MinimumOSVersion']))
        checks['purpose_strings'] = all(isinstance(info.get(k), str) and 0 < len(info[k].encode()) <= 1024 for k in ['NSCameraUsageDescription', 'NSLocalNetworkUsageDescription'])
        checks['qa_bundles_excluded'] = not any('.xctest' in p or 'nativeqatest' in p for p in inventory.entry_paths)
        privacy = app + 'PrivacyInfo.xcprivacy'
        checks['app_privacy_reasons'] = privacy in inventory.metadata and privacy_ok(inventory.metadata[privacy])
        checks['icon_resources_present'] = any(p.startswith(app) and (p.endswith('Assets.car') or re.search(r'/AppIcon[^/]*\.png$', p)) for p in paths)
        selected = {'appInfo': paths[apps[0]], 'archiveInfo': paths['Info.plist']}
        if privacy in paths:
            selected['appPrivacy'] = paths[privacy]
        # Parse every bundled privacy plist, but do not certify third-party declarations.
        for p, data in inventory.metadata.items():
            if p.startswith(app) and p.endswith('.xcprivacy'):
                require(isinstance(plist(data), dict))
        notices = [p for p in paths if p.startswith(app) and notice(p)]
    else:
        manifests = [p for p in paths if p.endswith('/manifest/AndroidManifest.xml')]
        require(manifests == ['base/manifest/AndroidManifest.xml'])
        manifest = manifest_node(inventory.metadata[manifests[0]])
        require(manifest and manifest['tag'] == 'manifest' and not manifest['namespace'])
        apps = [n for n in manifest['children'] if n['tag'] == 'application' and not n['namespace']]
        require(len(apps) == 1)
        app = apps[0]
        checks['identity'] = attribute(manifest, 'package', '') == 'com.thumble.android'
        checks['version'] = attribute(manifest, 'versionCode') == build and attribute(manifest, 'versionName') == version
        checks['not_debuggable'] = attribute(app, 'debuggable', default='false') == 'false'
        checks['backup_disabled'] = attribute(app, 'allowBackup') == 'false'
        expected = {'android.permission.INTERNET', 'android.permission.VIBRATE', 'android.permission.CAMERA', 'com.thumble.android.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION'}
        require(all(not n['namespace'] for n in manifest['children'] if n['tag'] in ('uses-sdk', 'application', 'uses-permission', 'uses-feature', 'instrumentation')))
        require(not any(n['tag'].startswith('uses-permission') and n['tag'] != 'uses-permission' for n in manifest['children']))
        sdk = [n for n in manifest['children'] if n['tag'] == 'uses-sdk']
        require(len(sdk) == 1)
        minimum, target = attribute(sdk[0], 'minSdkVersion'), attribute(sdk[0], 'targetSdkVersion')
        checks['sdk_versions_declared'] = bool(re.fullmatch(r'[1-9][0-9]{0,2}', minimum) and re.fullmatch(r'[1-9][0-9]{0,2}', target) and int(minimum) <= int(target))
        permissions = [attribute(n, 'name') for n in manifest['children'] if n['tag'] == 'uses-permission']
        checks['permissions'] = len(permissions) == len(set(permissions)) and set(permissions) == expected
        checks['camera_optional'] = any(n['tag'] == 'uses-feature' and attribute(n, 'name') == 'android.hardware.camera' and attribute(n, 'required', default='true') == 'false' for n in manifest['children'] if n['tag'] == 'uses-feature')
        checks['qa_excluded'] = not any(n['tag'] == 'instrumentation' for n in manifest['children']) and not any('nativeqa' in p or '.xctest' in p for p in inventory.entry_paths)
        checks['icons_declared'] = (ANDROID, 'icon') in app['attrs']
        checks['dex_present'] = 'base/dex/classes.dex' in paths
        selected['baseManifest'] = paths[manifests[0]]
        notices = [p for p in paths if p.startswith('base/assets/') and notice(p)]
    checks['notice_files_present'] = any(bool(inventory.metadata.get(p)) for p in notices)
    notice_digest = hashlib.sha256()
    for p in sorted(notices):
        notice_digest.update(p.encode() + b'\0' + paths[p].encode() + b'\n')
    return {'kind': 'mobile-store-artifact-review', 'platform': platform, 'ok': all(checks.values()),
            'checks': checks, 'inventory': inventory.summary(), 'metadataSHA256': selected,
            'noticeFileCount': len(notices), 'noticeInventorySHA256': notice_digest.hexdigest(),
            'privacyManifestCount': sum(p.endswith('.xcprivacy') for p in paths), 'signingStatus': 'unverified', 'distributionAccepted': False,
            'unverifiedChecks': ['signature-certificate-provisioning', 'complete-third-party-notices', 'store-privacy-labels', 'runtime-qa-code-exclusion', 'icon-visual-identity', 'gameplay-and-live-sync'] + (['ios-debug-entitlement'] if platform == 'ios' else [])}


class FixedArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise Invalid()


def main():
    parser = FixedArgumentParser(description=__doc__)
    parser.add_argument('--platform', required=True, choices=['ios', 'android'])
    parser.add_argument('--artifact', required=True, type=Path)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    args = parser.parse_args()
    require(re.fullmatch(r'(?:0|[1-9][0-9]{0,2})\.(?:0|[1-9][0-9]{0,2})\.(?:0|[1-9][0-9]{0,2})', args.version) and re.fullmatch(r'[1-9][0-9]{0,3}', args.build))
    result = audit(args.artifact, args.platform, args.version, args.build)
    print(json.dumps(result, separators=(',', ':')))
    return 0 if result['ok'] else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError, AttributeError, UnicodeError, zipfile.BadZipFile, zlib.error, RecursionError, RuntimeError, plistlib.InvalidFileException):
        print(json.dumps({'ok': False, 'error': 'store_artifact_invalid_or_unsupported', 'distributionAccepted': False, 'signingStatus': 'unverified'}))
        sys.exit(1)
