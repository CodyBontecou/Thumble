// CI only: create and boot a dedicated iPhone simulator for the selected Xcode, then
// print `udid=<id>` for $GITHUB_OUTPUT. Booting here, with `simctl bootstatus`, waits as
// long as a cold boot takes; a boot started through `argent run boot-device` is cut off
// by the CLI's five-minute HTTP limit on fresh runners. The smoke test receives the
// booted device with --device and skips its own boot.
import { execFileSync } from 'node:child_process';
import { parseArgs } from 'node:util';

const { values } = parseArgs({ options: {
  name: { type: 'string', default: 'Thumble CI iPhone' },
  'allow-local': { type: 'boolean', default: false },
} });
if (!process.env.CI && !values['allow-local']) {
  throw new Error('ci-simulator creates and boots a simulator; run it in CI or pass --allow-local.');
}

const log = message => console.error(`[ci-simulator] ${message}`);
const pause = seconds => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, seconds * 1000);
const exec = (command, args) => execFileSync(command, args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'] }).trim();

// CoreSimulator can refuse connections for a while after the Xcode switch
// ("Unable to connect to simulator"), so every call is retried.
function retry(label, action, { attempts = 6, wait = 10 } = {}) {
  for (let attempt = 1; ; attempt++) {
    try { return action(); }
    catch (error) {
      const detail = String(error.stderr || error.message).trim().split('\n').slice(-2).join(' ');
      if (attempt >= attempts) throw new Error(`${label} failed after ${attempts} attempts: ${detail}`, { cause: error });
      log(`${label} failed (attempt ${attempt}/${attempts}): ${detail}. Retrying in ${wait * attempt}s.`);
      pause(wait * attempt);
    }
  }
}

const minor = version => version.split('.').slice(0, 2).join('.');
const newer = (a, b) => {
  const [x, y] = [a, b].map(value => value.split('.').map(Number));
  for (let i = 0; i < Math.max(x.length, y.length); i++) if ((x[i] ?? 0) !== (y[i] ?? 0)) return (x[i] ?? 0) - (y[i] ?? 0);
  return 0;
};
const iosRuntimes = () => JSON.parse(retry('simctl list runtimes', () => exec('xcrun', ['simctl', 'list', 'runtimes', '-j'])))
  .runtimes.filter(runtime => runtime.platform === 'iOS' && runtime.isAvailable);

const sdk = exec('xcrun', ['--sdk', 'iphonesimulator', '--show-sdk-version']);
log(`${exec('xcodebuild', ['-version']).replace(/\n/g, ' · ')} · iOS Simulator SDK ${sdk}`);

// The smoke test skips foldables, so only regular iPhones qualify; prefer a current model.
const preferred = ['iPhone 17 Pro', 'iPhone 17', 'iPhone 16 Pro', 'iPhone 16'];
const iphoneType = runtime => {
  const types = (runtime.supportedDeviceTypes ?? []).filter(type => type.productFamily === 'iPhone' && !/Duo|Fold|Flip/i.test(type.name));
  return preferred.map(name => types.find(type => type.name === name)).find(Boolean) ?? types[0];
};
const pick = list => list.find(item => minor(item.version) === minor(sdk) && iphoneType(item)) ??
  list.filter(iphoneType).sort((a, b) => newer(b.version, a.version))[0];

let runtime = pick(iosRuntimes());
if (!runtime || minor(runtime.version) !== minor(sdk)) {
  log(`No iOS ${minor(sdk)} simulator runtime with an iPhone is installed; downloading it.`);
  try { retry('xcodebuild -downloadPlatform iOS', () => exec('xcodebuild', ['-downloadPlatform', 'iOS']), { attempts: 3, wait: 20 }); }
  catch (error) { log(error.message); }
  runtime = pick(iosRuntimes());
}
if (!runtime) throw new Error('No available iOS simulator runtime with an iPhone device type.');
const type = iphoneType(runtime);

const udid = retry('simctl create', () => exec('xcrun', ['simctl', 'create', `${values.name} (${type.name})`, type.identifier, runtime.identifier]));
log(`Created ${type.name} on iOS ${runtime.version}: ${udid}. Booting…`);
const started = Date.now();
retry('simctl bootstatus', () => exec('xcrun', ['simctl', 'bootstatus', udid, '-b']), { attempts: 3, wait: 15 });
log(`Booted in ${Math.round((Date.now() - started) / 1000)}s.`);
console.log(`udid=${udid}`);
