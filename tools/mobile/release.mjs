import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { parseArgs } from 'node:util';
import { appIdentity, assertSmokeReport, fileHash, mobile, readJSON, root, run, sameSource, smokeTest, sourceIdentity, writeJSON } from './common.mjs';
import { smoke } from './ios-smoke.mjs';
import { verifyManifest } from './release-manifest.mjs';

const appId = '6826421489';

function extractIPA(ipa, directory) {
  const entries = run('unzip', ['-Z1', ipa]).split('\n');
  if (entries.some(entry => entry.startsWith('/') || entry.split('/').includes('..'))) throw new Error('Unsafe IPA entry.');
  run('ditto', ['-x', '-k', ipa, directory]);
  const payload = path.join(directory, 'Payload');
  const apps = readdirSync(payload).filter(name => name.endsWith('.app'));
  if (apps.length !== 1) throw new Error('Expected exactly one app in the IPA.');
  return path.join(payload, apps[0]);
}

function verify(directory) {
  const manifest = readJSON(path.join(directory, 'release.json'));
  const temporary = mkdtempSync(path.join(os.tmpdir(), 'thumble-release-verify-'));
  try {
    const ipa = path.join(directory, 'app.ipa');
    const app = extractIPA(ipa, temporary);
    const smokeDirectory = path.join(directory, 'smoke');
    const receipt = readJSON(path.join(smokeDirectory, 'smoke.json'));
    const reportHashes = [1, 2].map(pass => {
      const file = path.join(smokeDirectory, `launch-pass-${pass}.json`);
      assertSmokeReport(readJSON(file));
      return fileHash(file);
    });
    verifyManifest(manifest, {
      source: sourceIdentity(), ipaSha256: fileHash(ipa), app: appIdentity(app),
      lockSha256: fileHash(path.join(root, 'package-lock.json')),
      checkSha256: fileHash(path.join(directory, 'source-checks.log')),
      smokeSha256: fileHash(path.join(smokeDirectory, 'smoke.json')),
      smoke: receipt, testSha256: fileHash(smokeTest), reportHashes,
    });
    return manifest;
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
}

function prepare(directory, device, profile) {
  const source = sourceIdentity();
  if (existsSync(directory)) throw new Error('Use a new output directory for each release attempt.');
  mkdirSync(directory, { recursive: true });
  console.log('Checking the exact release source.');
  run('npm', ['run', 'mobile:check'], { log: path.join(directory, 'source-checks.log') });
  sameSource(source, sourceIdentity());
  const env = { ...process.env, THUMBLE_RELEASE_COMMIT: source.commit,
    THUMBLE_RELEASE_TREE: source.tree, THUMBLE_RELEASE_LOCK_SHA256: fileHash(path.join(root, 'package-lock.json')) };
  const ipa = path.join(directory, 'app.ipa');
  console.log('Building the production IPA locally with EAS.');
  run('npx', ['--yes', 'eas-cli@27.7.2', 'build', '--local', '--platform', 'ios', '--profile', profile,
    '--non-interactive', '--output', ipa], { cwd: mobile, env, log: path.join(directory, 'eas-build.log') });
  sameSource(source, sourceIdentity());
  const ipaSha256 = fileHash(ipa);
  const temporary = mkdtempSync(path.join(os.tmpdir(), 'thumble-release-prepare-'));
  try {
    const app = extractIPA(ipa, temporary);
    const identity = appIdentity(app);
    // Provenance must be embedded by the config plugin in the actual EAS build.
    if (identity.sourceCommit !== source.commit || identity.sourceTree !== source.tree ||
        identity.lockSha256 !== env.THUMBLE_RELEASE_LOCK_SHA256) throw new Error('IPA source provenance is missing or mismatched.');
    const receipt = smoke({ output: path.join(directory, 'smoke'), device, productionApp: app });
    sameSource(source, sourceIdentity());
    const manifest = {
      schemaVersion: 1, source, app: identity,
      artifact: { path: 'app.ipa', sha256: ipaSha256 },
      check: { path: 'source-checks.log', sha256: fileHash(path.join(directory, 'source-checks.log')) },
      smokeSha256: fileHash(path.join(directory, 'smoke/smoke.json')),
      smokeScope: 'Production JavaScript and assets on a Release simulator native build from the same source.',
      createdAt: new Date().toISOString(),
    };
    if (!receipt.productionBundle) throw new Error('Production bundle was not tested.');
    writeJSON(path.join(directory, 'release.json'), manifest);
    try { verify(directory); }
    catch (error) { rmSync(path.join(directory, 'release.json')); throw error; }
    console.log(`Verified release manifest written to ${path.join(directory, 'release.json')}`);
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
}

function upload(directory, manifest) {
  const receiptPath = path.join(directory, 'upload.json');
  if (existsSync(receiptPath)) throw new Error('An upload receipt already exists. Verify it before retrying an upload.');
  // The uploader receives a private copy of the verified bytes.
  const temporary = mkdtempSync(path.join(os.tmpdir(), 'thumble-upload-'));
  try {
    const ipa = path.join(temporary, 'app.ipa');
    cpSync(path.join(directory, 'app.ipa'), ipa);
    if (fileHash(ipa) !== manifest.artifact.sha256) throw new Error('IPA changed before upload.');
    const result = JSON.parse(run('asc', ['builds', 'upload', '--app', appId, '--ipa', ipa, '--wait', '--output', 'json']));
    if (!result.buildId) throw new Error('Upload did not return a processed ASC build ID. Inspect ASC before retrying.');
    writeJSON(receiptPath, { appId, buildId: result.buildId, artifactSha256: manifest.artifact.sha256,
      sourceCommit: manifest.source.commit, version: manifest.app.version, buildNumber: manifest.app.buildNumber });
    console.log(`Uploaded verified build ${result.buildId}. Receipt saved to ${receiptPath}`);
  } finally { rmSync(temporary, { recursive: true, force: true }); }
}

function submit(directory, manifest) {
  const receipt = readJSON(path.join(directory, 'upload.json'));
  if (receipt.appId !== appId || receipt.artifactSha256 !== manifest.artifact.sha256 ||
      receipt.sourceCommit !== manifest.source.commit || receipt.version !== manifest.app.version ||
      receipt.buildNumber !== manifest.app.buildNumber || !receipt.buildId) throw new Error('Upload receipt does not match the verified release.');
  const build = JSON.parse(run('asc', ['--read-only', 'builds', 'info', '--app', appId,
    '--version', manifest.app.version, '--build-number', manifest.app.buildNumber, '--platform', 'IOS', '--output', 'json']));
  if (build.data?.id !== receipt.buildId || build.data?.attributes?.version !== manifest.app.buildNumber ||
      build.data?.attributes?.processingState !== 'VALID') throw new Error('ASC build identity or processing state differs.');
  console.log(run('asc', ['review', 'submit', '--app', appId, '--version', manifest.app.version,
    '--build-id', receipt.buildId, '--confirm', '--output', 'json']));
}

const { values, positionals } = parseArgs({ allowPositionals: true, options: {
  output: { type: 'string', default: path.join(root, 'build/mobile-release') },
  device: { type: 'string' }, profile: { type: 'string', default: 'production' }, confirm: { type: 'boolean', default: false },
} });
const directory = path.resolve(values.output);
const command = positionals[0];
if (positionals.length !== 1 || !['prepare', 'verify', 'upload', 'submit'].includes(command)) {
  throw new Error('Usage: npm run mobile:release -- prepare|verify|upload|submit --output build/RELEASE [--device UDID] [--confirm]');
}
if (command === 'prepare') {
  if (!['production', 'production-local'].includes(values.profile)) throw new Error('Select a production build profile.');
  prepare(directory, values.device, values.profile);
} else if (command === 'verify') {
  verify(directory);
  console.log('Source, IPA, and both launch reports match.');
} else {
  if (!values.confirm) throw new Error('Upload and App Review submission require --confirm.');
  const lock = path.join(directory, '.asc-operation');
  writeFileSync(lock, `${command}\n`, { flag: 'wx' });
  try {
    const manifest = verify(directory);
    if (command === 'upload') upload(directory, manifest);
    else submit(directory, manifest);
  } finally { rmSync(lock, { force: true }); }
}
