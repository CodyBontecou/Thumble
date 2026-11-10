import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { assertSmokeReport, sourceIdentity } from '../mobile/common.mjs';
import { verifyManifest } from '../mobile/release-manifest.mjs';

function fixture() {
  const source = { commit: 'a'.repeat(40), tree: 'b'.repeat(40), dirty: false };
  const app = { bundleId: 'com.thumble.ios', version: '1.0.0', buildNumber: '7', platform: 'iPhoneOS',
    sourceCommit: source.commit, sourceTree: source.tree, lockSha256: 'lock',
    bundleSha256: 'bundle', assetsSha256: 'assets' };
  const manifest = { schemaVersion: 1, source, app,
    artifact: { sha256: 'ipa' }, check: { sha256: 'checks' }, smokeSha256: 'smoke' };
  const actual = { source: { ...source }, app: { ...app }, ipaSha256: 'ipa', lockSha256: 'lock',
    checkSha256: 'checks', smokeSha256: 'smoke', testSha256: 'test', reportHashes: ['pass1', 'pass2'],
    smoke: { source: { ...source }, configuration: 'Release', platform: 'ios-simulator', productionBundle: true,
      app: { ...app }, testSha256: 'test', reports: [{ sha256: 'pass1' }, { sha256: 'pass2' }] } };
  return { manifest, actual };
}

test('a verified production payload with two matching launch reports is accepted', () => {
  const { manifest, actual } = fixture();
  verifyManifest(manifest, actual);
});

for (const [name, mutate] of [
  ['modified IPA', value => { value.ipaSha256 = 'another'; }],
  ['different commit', value => { value.source.commit = 'c'.repeat(40); }],
  ['dirty checkout', value => { value.source.dirty = true; }],
  ['missing embedded source provenance', value => { delete value.app.sourceCommit; }],
  ['different dependency lock', value => { value.lockSha256 = 'another'; }],
  ['modified check log', value => { value.checkSha256 = 'another'; }],
  ['modified smoke receipt', value => { value.smokeSha256 = 'another'; }],
  ['changed smoke test', value => { value.testSha256 = 'another'; }],
  ['development build', value => { value.smoke.configuration = 'Debug'; }],
  ['simulator-only bundle', value => { value.smoke.productionBundle = false; }],
  ['different tested JavaScript', value => { value.smoke.app.bundleSha256 = 'another'; }],
  ['different tested assets', value => { value.smoke.app.assetsSha256 = 'another'; }],
  ['only one launch pass', value => { value.smoke.reports.pop(); }],
  ['modified launch report', value => { value.reportHashes[1] = 'another'; }],
]) {
  test(`release gate rejects ${name}`, () => {
    const { manifest, actual } = fixture();
    mutate(actual);
    assert.throws(() => verifyManifest(manifest, actual));
  });
}

test('a skipped, failed, empty, or warning-bearing launch report cannot count as a pass', () => {
  const report = { e2eTest: 'qa-ios-release-launch', ok: true, passed: 5,
    steps: ['script', 'launch', 'await', 'idle', 'assert'].map(kind => ({ kind, status: 'pass' })) };
  assertSmokeReport(report);
  for (const mutate of [
    value => { value.ok = false; },
    value => { value.steps = []; },
    value => { value.steps[4].status = 'skipped'; },
    value => { value.steps[2].status = 'fail'; },
    value => { value.steps[3].reason = 'tree unreadable'; },
  ]) {
    const invalid = structuredClone(report);
    mutate(invalid);
    assert.throws(() => assertSmokeReport(invalid));
  }
});

test('release source validation rejects both uncommitted edits and untracked source', () => {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'thumble-release-source-'));
  const git = args => execFileSync('git', args, { cwd: directory, stdio: 'pipe' });
  try {
    git(['init']);
    writeFileSync(path.join(directory, 'app.js'), 'export const value = 1;\n');
    git(['add', '.']);
    git(['-c', 'user.name=Release Test', '-c', 'user.email=release@example.invalid', 'commit', '-m', 'fixture']);
    assert.equal(sourceIdentity(true, directory).dirty, false);
    writeFileSync(path.join(directory, 'extra.js'), 'untracked');
    assert.throws(() => sourceIdentity(true, directory), /clean committed/);
    rmSync(path.join(directory, 'extra.js'));
    writeFileSync(path.join(directory, 'app.js'), 'changed');
    assert.throws(() => sourceIdentity(true, directory), /clean committed/);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
