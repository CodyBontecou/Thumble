import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { closeSync, lstatSync, openSync, readFileSync, readdirSync, readlinkSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const root = fileURLToPath(new URL('../../', import.meta.url));
export const mobile = path.join(root, 'apps/mobile');
export const smokeTest = path.join(root, '.argent/e2e/qa-ios-release-launch.yaml');

export function run(command, args, { cwd = root, env = process.env, log } = {}) {
  const fd = log ? openSync(log, 'w') : null;
  try {
    return execFileSync(command, args, {
      cwd, env, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024,
      stdio: fd === null ? ['ignore', 'pipe', 'inherit'] : ['ignore', fd, fd],
    })?.trim();
  } catch (error) {
    throw new Error(`${command} failed${log ? `; see ${log}` : ''}`, { cause: error });
  } finally {
    if (fd !== null) closeSync(fd);
  }
}

export const readJSON = file => JSON.parse(readFileSync(file, 'utf8'));
export const writeJSON = (file, value) => writeFileSync(file, JSON.stringify(value, null, 2) + '\n');
export const fileHash = file => createHash('sha256').update(readFileSync(file)).digest('hex');

export function directoryHash(directory) {
  const hash = createHash('sha256');
  function visit(relative) {
    const file = path.join(directory, relative);
    const stat = lstatSync(file);
    if (stat.isDirectory()) {
      for (const name of readdirSync(file).sort()) visit(path.join(relative, name));
    } else {
      hash.update(JSON.stringify([relative, stat.isSymbolicLink() ? 'link' : 'file']));
      hash.update(stat.isSymbolicLink() ? readlinkSync(file) : readFileSync(file));
    }
  }
  visit('');
  return hash.digest('hex');
}

export function sourceIdentity(requireClean = true, cwd = root) {
  const dirty = run('git', ['status', '--porcelain', '--untracked-files=all'], { cwd }) !== '';
  if (requireClean && dirty) throw new Error('Release requires a clean committed checkout, including untracked files.');
  return {
    commit: run('git', ['rev-parse', 'HEAD'], { cwd }),
    tree: run('git', ['rev-parse', 'HEAD^{tree}'], { cwd }),
    dirty,
  };
}

export function sameSource(expected, actual) {
  if (expected.dirty || actual.dirty || expected.commit !== actual.commit || expected.tree !== actual.tree) {
    throw new Error('Validation source differs from the clean release source.');
  }
}

// `argent run --json` returns the raw MCP result, while `argent e2e --json`
// returns its report directly.
export function argentTool(name, args = {}) {
  const result = JSON.parse(run('argent', ['run', name, '--args', JSON.stringify(args), '--json']));
  if (result.isError) throw new Error(JSON.stringify(result.content));
  const text = result.content?.find(item => item.type === 'text')?.text;
  return text ? JSON.parse(text) : result;
}

export function assertSmokeReport(report) {
  const expected = ['script', 'launch', 'await', 'idle', 'assert'];
  if (report.ok !== true || report.e2eTest !== 'qa-ios-release-launch' || report.passed !== expected.length ||
      !Array.isArray(report.steps) || report.steps.length !== expected.length ||
      report.steps.some((step, index) => step.kind !== expected[index] || step.status !== 'pass' ||
        step.reason || step.warning || step.warnings?.length)) {
    throw new Error('Launch smoke test did not pass every step without warnings.');
  }
}

export function appIdentity(app) {
  const info = JSON.parse(run('plutil', ['-convert', 'json', '-o', '-', path.join(app, 'Info.plist')]));
  if (info.CFBundleIdentifier !== 'com.thumble.ios') throw new Error('Unexpected iOS bundle identifier.');
  if (!info.CFBundleShortVersionString || !info.CFBundleVersion) throw new Error('Missing app version or build number.');
  return {
    bundleId: info.CFBundleIdentifier,
    version: String(info.CFBundleShortVersionString),
    buildNumber: String(info.CFBundleVersion),
    platform: info.CFBundleSupportedPlatforms?.[0],
    bundleSha256: fileHash(path.join(app, 'main.jsbundle')),
    assetsSha256: directoryHash(path.join(app, 'assets')),
    sourceCommit: info.ThumbleSourceCommit,
    sourceTree: info.ThumbleSourceTree,
    lockSha256: info.ThumbleLockSHA256,
  };
}
