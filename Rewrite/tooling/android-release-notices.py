#!/usr/bin/env python3
"""Read-only release provenance inventory. A text match is not license clearance."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import zipfile

MAX_FILE = 256 * 1024 * 1024
MAX_TEXT = 2 * 1024 * 1024
MAX_ENTRIES = 20000
NOTICE = re.compile(r"(?:licen[cs]e|copying|notice|copyright)(?:[._-].*)?", re.I)
B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"


def read(path, cap=MAX_FILE):
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), 'rb') as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError('not_regular_file')
        value = stream.read(cap + 1)
    if len(value) > cap:
        raise ValueError('file_limit')
    return value


def sha(value):
    return hashlib.sha256(value).hexdigest()


def file_sha(path):
    digest = hashlib.sha256()
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), "rb") as stream:
        size = os.fstat(stream.fileno()).st_size
        if size > 512 * 1024 * 1024:
            raise ValueError("archive_limit")
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load(path):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError('duplicate_json_key')
            result[key] = value
        return result
    return json.loads(read(path), object_pairs_hook=pairs)


def safe_name(name):
    if not isinstance(name, str) or len(name) > 1024 or '\\' in name or '\x00' in name:
        raise ValueError('invalid_member_name')
    parts = name.rstrip('/').split('/')
    if name.startswith('/') or any(p in ('', '.', '..') for p in parts):
        raise ValueError('invalid_member_name')
    return name


def members(path):
    """No extraction; cap metadata/expanded member reads, reject ambiguous paths."""
    if Path(path).is_symlink() or Path(path).stat().st_size > 512 * 1024 * 1024:
        raise ValueError('archive_limit')
    with zipfile.ZipFile(path) as archive:
        infos = archive.infolist()
        if len(infos) > MAX_ENTRIES or sum(i.file_size for i in infos) > 2 * 1024 * 1024 * 1024:
            raise ValueError('zip_entry_limit')
        seen = set()
        for info in infos:
            name = safe_name(info.filename)
            if info.is_dir():
                continue
            if name.casefold() in seen:
                raise ValueError('zip_duplicate_member')
            seen.add(name.casefold())
            if stat.S_ISLNK(info.external_attr >> 16) or info.flag_bits & 1:
                raise ValueError('zip_unsupported_member')
            if info.is_dir():
                continue
            yield archive, info


def zip_read(archive, info, cap=MAX_FILE):
    if info.file_size > cap:
        raise ValueError('zip_member_limit')
    with archive.open(info) as stream:
        result = stream.read(cap + 1)
    if len(result) != info.file_size:
        raise ValueError('zip_member_size')
    return result


def referenced_sources(mapping, source_count):
    """Decode source-map VLQ; only source-bearing segments establish provenance."""
    if not isinstance(mapping, str) or len(mapping) > MAX_FILE:
        raise ValueError('mapping_limit')
    source = original_line = original_column = name_index = 0
    used = set()
    for line in mapping.split(';'):
        generated = 0
        for segment in line.split(','):
            if not segment:
                continue
            values = []
            value = shift = 0
            for char in segment:
                if char not in B64 or shift > 30:
                    raise ValueError('mapping_vlq')
                digit = B64.index(char)
                value |= (digit & 31) << shift
                if digit & 32:
                    shift += 5
                else:
                    values.append(-(value >> 1) if value & 1 else value >> 1)
                    value = shift = 0
            if shift or len(values) not in (1, 4, 5):
                raise ValueError('mapping_segment')
            generated += values[0]
            if generated < 0:
                raise ValueError('mapping_column')
            if len(values) > 1:
                source += values[1]
                original_line += values[2]
                original_column += values[3]
                if source < 0 or source >= source_count or min(original_line, original_column) < 0:
                    raise ValueError('mapping_source')
                used.add(source)
                if len(values) == 5:
                    name_index += values[4]
                    if name_index < 0:
                        raise ValueError('mapping_name')
    return used


class Texts:
    def __init__(self):
        self.values = {}
        self.total = 0

    def add(self, value):
        if not value or len(value) > MAX_TEXT or b'\x00' in value:
            raise ValueError('notice_text_invalid')
        value.decode('utf-8')
        digest = sha(value)
        if digest not in self.values:
            self.total += len(value)
            if self.total > 32 * 1024 * 1024 or len(self.values) >= 2048:
                raise ValueError("notice_total_limit")
        self.values[digest] = value
        return {'sha256': digest, 'byteCount': len(value)}


def local_notices(directory, texts):
    found = []
    for path in sorted(directory.iterdir()):
        if path.is_file() and NOTICE.fullmatch(path.name):
            found.append({'name': path.name, **texts.add(read(path, MAX_TEXT))})
    return found


def package_owner(root, source):
    if not isinstance(source, str) or len(source) > 4096:
        raise ValueError('source_name')
    if source.startswith('\x00'):
        return None, 'generated_origin_unresolved'
    relative = source.lstrip('/')
    safe_name(relative)
    path = root / relative
    # Bun's physical package store is inside this fresh private build root.
    resolved = path.resolve()
    if not resolved.is_relative_to(root):
        raise ValueError('source_outside_root')
    if 'node_modules' not in Path(relative).parts:
        return None, 'first_party' if relative.startswith(('apps/', 'packages/')) else 'unknown_origin'
    current = resolved.parent
    while current != root:
        candidate = current / 'package.json'
        if candidate.is_file():
            metadata = load(candidate)
            if isinstance(metadata.get('name'), str) and isinstance(metadata.get('version'), str):
                return (current, metadata), None
        current = current.parent
    return None, 'package_owner_unresolved'


def javascript(root, source_map, texts):
    data = load(source_map)
    sources = data.get('sources')
    if data.get('version') != 3 or not isinstance(sources, list) or len(sources) > 20000:
        raise ValueError('source_map_shape')
    used = referenced_sources(data.get('mappings'), len(sources))
    packages = {}
    unresolved = []
    first_party = 0
    for index in sorted(used):
        owner, classification = package_owner(root, sources[index])
        if owner is None:
            if classification == 'first_party':
                first_party += 1
            else:
                unresolved.append({'sourceIndex': index, 'reason': classification})
            continue
        directory, metadata = owner
        key = metadata['name'] + '@' + metadata['version']
        if key not in packages:
            packages[key] = {'component': key, 'packageJsonSHA256': sha(read(directory / 'package.json')),
                             'texts': local_notices(directory, texts), 'sourceIndices': []}
        packages[key]['sourceIndices'].append(index)
    return {'sourceMapSHA256': sha(read(source_map)), 'sourceCount': len(sources),
            'referencedSourceCount': len(used), 'firstPartySourceCount': first_party,
            'packages': sorted(packages.values(), key=lambda x: x['component']), 'unresolved': unresolved}


def maven(graph, cache, texts):
    result = []
    native = {}
    archive_count = archive_bytes = 0
    for item in graph['components']:
        key = item['key']
        if not key.startswith('m:'):
            result.append({'component': key, 'texts': [], 'reason': 'project_component_requires_source_notices'})
            continue
        parts = key.split(':')
        if len(parts) != 4 or any(not re.fullmatch(r'[A-Za-z0-9_.+\-]+', p) for p in parts[1:]):
            raise ValueError('component_id')
        _, group, name, version = parts
        directory = cache / group / name / version
        archives = []
        notices = []
        if directory.is_dir():
            selected = [Path(a['file']) for a in graph.get('archives', []) if a['component'] == key]
            paths = selected or list(directory.glob('*/' + name + '-' + version + '.jar'))
            if len(paths) > 16:
                raise ValueError('component_archive_limit')
            for path in paths:
                if not path.resolve().is_relative_to(directory.resolve()):
                    raise ValueError('artifact_outside_component_cache')
            for path in sorted(paths):
                if path.suffix not in ('.aar', '.jar'):
                    continue
                archive_count += 1
                archive_bytes += path.stat().st_size
                if archive_count > 1024 or archive_bytes > 4 * 1024 * 1024 * 1024:
                    raise ValueError('archive_total_limit')
                archives.append({'name': path.name, 'sha256': file_sha(path)})
                for archive, info in members(path):
                    if NOTICE.fullmatch(Path(info.filename).name):
                        notices.append({'archive': path.name, 'member': info.filename,
                                        **texts.add(zip_read(archive, info, MAX_TEXT))})
                    elif re.fullmatch(r'(?:jni/arm64-v8a|prefab/modules/[^/]+/libs/android\.arm64-v8a)/[^/]+\.so', info.filename):
                        value = zip_read(archive, info)
                        native.setdefault((Path(info.filename).name, sha(value)), []).append(
                            {'component': key, 'archiveSHA256': archives[-1]['sha256'], 'member': info.filename})
        result.append({'component': key, 'archives': archives, 'texts': notices,
                       'reason': 'embedded_dependency_notices_unverified' if notices else 'license_text_not_in_cached_archive'})
    return result, native


def project_native_sources(root, graph, texts):
    owners = {}
    packages = []
    for component in graph['components']:
        if not component['key'].startswith('p:') or not component.get('projectDirectory'):
            continue
        directory = Path(component['projectDirectory']).resolve()
        if not directory.is_relative_to(root):
            raise ValueError('project_outside_root')
        current = directory
        package = None
        while current != root:
            if (current / 'package.json').is_file():
                candidate = load(current / 'package.json')
                if candidate.get('name') and candidate.get('version'):
                    package = {'component': component['key'], 'npmComponent': candidate['name'] + '@' + candidate['version'],
                               'texts': local_notices(current, texts)}
                    break
            current = current.parent
        if package:
            packages.append(package)
        count = 0
        for search in (directory / 'build', directory / '.cxx'):
            if not search.is_dir():
                continue
            for base, dirs, files in os.walk(search, followlinks=False):
                dirs[:] = sorted(d for d in dirs if not Path(base, d).is_symlink())
                count += len(files) + len(dirs)
                if count > 100000:
                    raise ValueError('project_build_entry_limit')
                for name in sorted(files):
                    path = Path(base, name)
                    if name.endswith('.so') and 'arm64-v8a' in path.parts and 'obj' in path.parts:
                        digest = file_sha(path)
                        owner = {'component': component['key'], 'buildMember': path.relative_to(directory).as_posix()}
                        matches = owners.setdefault((name, digest), [])
                        if len(matches) >= 16:
                            raise ValueError('native_match_limit')
                        matches.append(owner)
    return owners, packages


def upstream_supplement(js, inventory_path, bundle_path, texts):
    if not inventory_path and not bundle_path:
        return None
    if not inventory_path or not bundle_path:
        raise ValueError('upstream_pair_required')
    proof = load(inventory_path)
    bundle = read(bundle_path, 8 * MAX_TEXT)
    if proof.get('schemaVersion') != 1 or proof.get('bundleSHA256') != sha(bundle) or proof.get('bundleByteCount') != len(bundle):
        raise ValueError('upstream_bundle_mismatch')
    selected = proof.get('selectedTexts')
    if not isinstance(selected, list) or len(selected) > 1000:
        raise ValueError('upstream_text_limit')
    packages = {p['component']: p for p in js['packages']}
    for text in selected:
        start, count = text.get('offset'), text.get('byteCount')
        if type(start) is not int or type(count) is not int or start < 0 or count < 1 or count > MAX_TEXT or start + count > len(bundle):
            raise ValueError('upstream_text_bounds')
        value = bundle[start:start + count]
        if sha(value) != text.get('sha256'):
            raise ValueError('upstream_text_mismatch')
        for origin in text.get('origins', []):
            if origin.get('kind') != 'npm-release-gitHead-upstream-license':
                continue
            key = origin.get('component', '') + '@' + origin.get('version', '')
            if key not in packages:
                continue
            package = packages[key]
            commit = origin.get('gitHead')
            url = origin.get('url')
            if (package['packageJsonSHA256'] != origin.get('packageJsonSHA256') or
                    not isinstance(commit, str) or not re.fullmatch('[a-f0-9]{40}', commit) or
                    not isinstance(url, str) or not re.fullmatch(r'https://raw\.githubusercontent\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/' + commit + r'/LICENSE', url)):
                raise ValueError('upstream_component_mismatch')
            package.setdefault('upstreamTexts', []).append({**texts.add(value), 'gitHead': commit, 'url': url})
    return {'inventorySHA256': file_sha(inventory_path), 'bundleSHA256': sha(bundle),
            'verificationScope': 'audited_external_manifest_exact_package_json_and_pinned_text_match'}


def inventory(args):
    root = Path(args.root).resolve()
    texts = Texts()
    graph = load(args.graph)
    if graph.get('schema') != 1 or graph.get('configuration') != 'releaseRuntimeClasspath' or len(graph.get('components', [])) > 2000:
        raise ValueError('graph_shape')
    js = javascript(root, args.source_map, texts)
    supplement = upstream_supplement(js, getattr(args, 'upstream_inventory', None), getattr(args, 'upstream_bundle', None), texts)
    java, native_owners = maven(graph, Path(args.maven_cache), texts)
    project_owners, project_packages = project_native_sources(root, graph, texts)
    app_build = root / 'apps/mobile/android/app/build'
    native = []
    packaged_notices = []
    bundle_member = None
    scanner_text = None
    for archive, info in members(args.aab):
        if NOTICE.fullmatch(Path(info.filename).name) or 'notices' in Path(info.filename).name.lower():
            packaged_notices.append({'member': info.filename, **texts.add(zip_read(archive, info, MAX_TEXT))})
        if info.filename == 'base/assets/thumble-qr-notices.txt':
            scanner_text = zip_read(archive, info, MAX_TEXT).decode('utf-8')
        if info.filename == 'base/assets/index.android.bundle':
            bundle_member = sha(zip_read(archive, info))
        if re.fullmatch(r'base/lib/arm64-v8a/[^/]+\.so', info.filename):
            name = Path(info.filename).name
            packaged_hash = sha(zip_read(archive, info))
            stripped = app_build / 'intermediates/stripped_native_libs/release/stripReleaseDebugSymbols/out/lib/arm64-v8a' / name
            merged = app_build / 'intermediates/merged_native_libs/release/mergeReleaseNativeLibs/out/lib/arm64-v8a' / name
            stripped_hash = sha(read(stripped)) if stripped.is_file() else None
            merged_hash = sha(read(merged)) if merged.is_file() else None
            matches = native_owners.get((name, merged_hash), [])
            native.append({'member': info.filename, 'sha256': packaged_hash,
                           'strippedOutputSHA256': stripped_hash, 'strippedMatchesPackage': stripped_hash == packaged_hash,
                           'mergedOutputSHA256': merged_hash, 'exactAAROwners': matches, 'matchingProjectBuildCopies': project_owners.get((name, merged_hash), []),
                           'reason': 'static_vendored_dependencies_unverified' if matches else 'project_or_transformed_native_owner_unresolved'})
    built_bundle = app_build / 'generated/assets/react/release/index.android.bundle'
    built_hash = sha(read(built_bundle)) if built_bundle.is_file() else None
    if bundle_member is None or bundle_member != built_hash:
        raise ValueError('hermes_bundle_mismatch')
    if any(not item['strippedMatchesPackage'] for item in native):
        raise ValueError('native_package_mismatch')
    scanner_components = sorted(c['key'][2:] for c in graph['components'] if c['key'].startswith(('m:com.journeyapps:zxing-android-embedded:', 'm:com.google.zxing:core:')))
    scanner = {'resolvedComponents': scanner_components,
               'coordinateTextMatches': scanner_text is not None and len(scanner_components) == 2 and all(c in scanner_text for c in scanner_components),
               'upstreamTextContentAuthenticity': 'not-revalidated-by-this-tool'}
    unresolved = [{'component': p['component'], 'reason': 'npm_license_text_missing'} for p in js['packages'] if not p['texts'] and not p.get('upstreamTexts')]
    unresolved += [{'sourceIndex': p['sourceIndex'], 'reason': p['reason']} for p in js['unresolved']]
    unresolved += [{'component': p['component'], 'reason': p['reason']} for p in java]
    unresolved += [{'member': p['member'], 'reason': p['reason']} for p in native]
    return {'schema': 1, 'complete': False, 'candidateTextsAreNotCompleteDistributionBundle': True, 'distributionAccepted': False,
            'unresolved': unresolved, 'aabSHA256': sha(read(args.aab)), 'lockSHA256': sha(read(root / 'bun.lock')),
            'graphSHA256': sha(read(args.graph)), 'hermesBundleSHA256': bundle_member,
            'resolvedRuntimeArtifacts': [{'component': a['component'], 'sha256': file_sha(a['file'])} for a in graph.get('artifacts', [])],
            'javascript': js, 'auditedUpstreamSupplement': supplement, 'releaseRuntimeClasspath': java,
            'scannerNoticeReconciliation': scanner, 'packagedNotices': packaged_notices, 'nativeLibraries': native, 'projectPackages': project_packages,
            'limitations': ['runtime_graph_is_pre_shrinker_superset', 'source_map_build_provenance_not_cryptographically_bound_to_hermes',
                            'matching_license_text_is_not_complete_embedded_dependency_coverage',
                            'matching_project_build_copies_do_not_prove_original_compilation_provenance',
                            'project_native_and_static_vendored_dependencies_require_pinned_source_audit']}, texts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('root', 'aab', 'source-map', 'graph', 'maven-cache', 'output'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--texts-directory', required=True)
    parser.add_argument('--upstream-inventory')
    parser.add_argument('--upstream-bundle')
    args = parser.parse_args()
    try:
        result, texts = inventory(args)
        # New directories/files only; never modify an existing artifact or notice bundle.
        target = Path(args.texts_directory)
        target.mkdir(mode=0o700)
        for digest, value in sorted(texts.values.items()):
            with open(target / (digest + '.txt'), 'xb') as stream:
                stream.write(value)
        with open(args.output, 'x', encoding='utf-8') as stream:
            json.dump(result, stream, indent=2, ensure_ascii=True)
            stream.write('\n')
    except (ValueError, KeyError, TypeError, OSError, zipfile.BadZipFile, UnicodeError, AttributeError, OverflowError, RecursionError):
        parser.exit(1, 'android_release_notice_inventory_failed\n')


if __name__ == '__main__':
    main()
