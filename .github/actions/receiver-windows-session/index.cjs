const fs = require('node:fs');
const path = require('node:path');
const {spawn, spawnSync} = require('node:child_process');
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));

(async () => {
  const {DefaultArtifactClient} = await import('@actions/artifact');
  const artifact = new DefaultArtifactClient();
  const directory = path.join(process.env.RUNNER_TEMP, 'thumble-ios-session');
  fs.mkdirSync(directory, {recursive: true});
  const output = fs.openSync(path.join(directory, 'coordinator.log'), 'w');
  const errors = fs.openSync(path.join(directory, 'coordinator-error.log'), 'w');
  const child = spawn('python', ['-u', path.join(process.env.GITHUB_WORKSPACE, 'scripts/receiver-qa/windows-ios-session.py'), '--directory', directory, '--public-key', process.env.OPERATOR_PUBLIC_KEY], {stdio: ['ignore', output, errors]});
  let exitCode;
  child.on('exit', code => { exitCode = code ?? 1; });
  child.on('error', () => { exitCode = 1; });
  try {
    const descriptor = path.join(directory, 'connection.bin');
    for (let i = 0; !fs.existsSync(descriptor); i++) {
      if (exitCode !== undefined) throw new Error('Windows session setup failed');
      if (i >= 180) throw new Error('Windows session setup timed out');
      await pause(1000);
    }
    await artifact.uploadArtifact('windows-ios-encrypted-connection', [descriptor], directory, {retentionDays: 1});
    console.log('Windows desktop ready; waiting for actual iOS app input.');
    for (let i = 0; exitCode === undefined; i++) {
      if (i >= 16 * 60) throw new Error('iOS acceptance timed out');
      await pause(1000);
    }
    const resultPath = path.join(directory, 'evidence', 'result.json');
    if (exitCode !== 0 || !fs.existsSync(resultPath) || !JSON.parse(fs.readFileSync(resultPath)).accepted) {
      throw new Error('Actual iOS desktop acceptance did not pass');
    }
    console.log('Actual iOS to Windows desktop acceptance passed.');
  } catch (error) {
    console.error(`::error::${error.message}`);
    for (const name of ['coordinator-error.log', 'desktop.log', 'tunnel.log']) {
      const file = path.join(directory, name);
      if (fs.existsSync(file)) {
        // Tunnel logs contain only its public hostname, never the private path token.
        const text = fs.readFileSync(file, 'utf8').replace(/https:\/\/[a-z0-9-]+\.trycloudflare\.com/g, '[temporary tunnel hostname]');
        console.log(`${name}:\n${text.split('\n').slice(-35).join('\n')}`);
      }
    }
    process.exitCode = 1;
  } finally {
    if (exitCode === undefined) spawnSync('taskkill', ['/PID', String(child.pid), '/T', '/F'], {stdio: 'ignore'});
    fs.closeSync(output); fs.closeSync(errors);
    const evidence = path.join(directory, 'evidence');
    if (fs.existsSync(evidence)) {
      const files = fs.readdirSync(evidence).filter(name => /\.(json|png)$/.test(name)).map(name => path.join(evidence, name));
      if (files.length) await artifact.uploadArtifact('windows-ios-desktop-evidence', files, evidence, {retentionDays: 7});
    }
  }
})().catch(error => { console.error(`::error::${error.message}`); process.exitCode = 1; });
