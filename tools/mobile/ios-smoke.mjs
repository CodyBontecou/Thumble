import { cpSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { parseArgs } from 'node:util';
import { fileURLToPath } from 'node:url';
import { appIdentity, argentTool, assertSmokeReport, directoryHash, fileHash, readJSON, root, run, sameSource, smokeTest, sourceIdentity, writeJSON } from './common.mjs';

function buildSimulator({ output, target, source, allowDirty }) {
  const temporary = allowDirty ? null : mkdtempSync(path.join(os.tmpdir(), 'thumble-simulator-source-'));
  const checkout = temporary ? path.join(temporary, 'source') : root;
  try {
    if (temporary) {
      mkdirSync(checkout);
      const archive = path.join(temporary, 'source.tar');
      run('git', ['archive', '--format=tar', '--output', archive, source.commit]);
      run('tar', ['-xf', archive, '-C', checkout]);
      run('npm', ['ci', '--no-audit', '--no-fund'], { cwd: checkout, log: path.join(output, 'install.log') });
    }
    const mobile = path.join(checkout, 'apps/mobile');
    run('npx', ['--no-install', 'expo', 'prebuild', '--platform', 'ios', '--no-install'], { cwd: mobile, log: path.join(output, 'prebuild.log') });
    run('pod', ['install'], { cwd: path.join(mobile, 'ios'), log: path.join(output, 'pods.log') });
    const derivedData = path.join(output, 'derived-data');
    console.log(`Building Release for ${target.name}.`);
    run('xcodebuild', ['-workspace', path.join(mobile, 'ios/Thumble.xcworkspace'), '-scheme', 'Thumble',
      '-configuration', 'Release', '-sdk', 'iphonesimulator', '-destination', `id=${target.udid}`,
      '-derivedDataPath', derivedData, 'ONLY_ACTIVE_ARCH=YES', 'CODE_SIGNING_ALLOWED=NO', 'build'],
    { log: path.join(output, 'xcodebuild.log') });
    return path.join(derivedData, 'Build/Products/Release-iphonesimulator/Thumble.app');
  } finally {
    if (temporary) rmSync(temporary, { recursive: true, force: true });
  }
}

export function smoke(options) {
  mkdirSync(path.join(root, 'build'), { recursive: true });
  const session = path.join(root, 'build/mobile-smoke-session.json');
  writeFileSync(session, '{}', { flag: 'wx' });
  try { return validateLaunch(options, session); }
  finally { rmSync(session, { force: true }); }
}

function validateLaunch({ output, device, simApp, productionApp, allowDirty = false }, session) {
  const source = sourceIdentity(!allowDirty);
  if (simApp && !allowDirty) throw new Error('A prebuilt simulator app is only supported for local QA with --allow-dirty.');
  mkdirSync(output, { recursive: true });
  const receiptPath = path.join(output, 'smoke.json');
  rmSync(receiptPath, { force: true });
  // argent reports no simulators when its 10 s `simctl` listing times out, which happens
  // while a freshly booted simulator keeps CoreSimulator busy; retry before giving up.
  let devices = [];
  for (let attempt = 1; attempt <= 8; attempt++) {
    ({ devices } = argentTool('list-devices'));
    if (devices.some(item => item.platform === 'ios' && (!device || item.udid === device))) break;
    if (attempt < 8) {
      console.error(`Simulator list is incomplete (attempt ${attempt}/8); retrying in 15 s.`);
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 15e3);
    }
  }
  const simulators = devices.filter(item => item.platform === 'ios' && item.kind !== 'device' &&
    item.runtimeKind === 'mobile' && !item.foldable && /iPhone/i.test(item.name));
  const booted = simulators.filter(item => item.state === 'Booted');
  if (!device && booted.length > 1) throw new Error('Select a dedicated simulator with --device UDID.');
  const target = device ? simulators.find(item => item.udid === device) : booted[0] ?? simulators[0];
  if (!target) throw new Error('No matching iPhone simulator. Install an iOS runtime in Xcode.');
  if (target.state !== 'Booted') argentTool('boot-device', { udid: target.udid, headless: true });

  simApp ??= buildSimulator({ output, target, source, allowDirty });

  // Work on a copy so a production-bundle test cannot alter the build product.
  const installedApp = path.join(output, 'install/Thumble.app');
  rmSync(installedApp, { recursive: true, force: true });
  cpSync(simApp, installedApp, { recursive: true });
  if (productionApp) {
    cpSync(path.join(productionApp, 'main.jsbundle'), path.join(installedApp, 'main.jsbundle'));
    rmSync(path.join(installedApp, 'assets'), { recursive: true, force: true });
    cpSync(path.join(productionApp, 'assets'), path.join(installedApp, 'assets'), { recursive: true });
  }
  const identity = appIdentity(installedApp);
  if (identity.platform !== 'iPhoneSimulator') throw new Error('The launch test requires an iPhone simulator app.');
  const appSha256 = directoryHash(installedApp);
  writeJSON(session, { appPath: installedApp, udid: target.udid });
  const reports = [];
  argentTool('stop-all-simulator-servers', { devices: [target.udid] });
  for (let pass = 1; pass <= 2; pass++) {
    const reportFile = path.join(output, `launch-pass-${pass}.json`);
    run('argent', ['e2e', 'run', smokeTest, '--platform', 'ios', '--device', target.udid,
      '--output', path.join(output, 'screenshots'), '--json'], { log: reportFile });
    assertSmokeReport(readJSON(reportFile));
    reports.push({ path: path.basename(reportFile), sha256: fileHash(reportFile) });
    console.log(`Clean-install Release launch pass ${pass}/2 succeeded.`);
  }
  if (directoryHash(installedApp) !== appSha256) throw new Error('Test app changed during validation.');
  if (!allowDirty) sameSource(source, sourceIdentity());
  const receipt = {
    schemaVersion: 1, source, configuration: 'Release', platform: 'ios-simulator',
    device: { name: target.name, runtime: target.runtime },
    app: identity, appSha256, productionBundle: Boolean(productionApp),
    testSha256: fileHash(smokeTest), reports,
  };
  writeJSON(receiptPath, receipt);
  return receipt;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const { values } = parseArgs({ options: {
    output: { type: 'string', default: path.join(root, 'build/mobile-smoke') },
    device: { type: 'string' }, 'sim-app': { type: 'string' }, 'allow-dirty': { type: 'boolean', default: false },
  } });
  smoke({ output: path.resolve(values.output), device: values.device,
    simApp: values['sim-app'] && path.resolve(values['sim-app']), allowDirty: values['allow-dirty'] });
}
