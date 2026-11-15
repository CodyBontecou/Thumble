// Run the SAME portable phone journey used by the Python receiver tests against
// the production Swift receiver. Only HID/desktop output is captured, never posted.
import { mkdtemp, mkdir, readFile, writeFile, copyFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { generateKeyPairSync } from 'node:crypto';

const folder = await mkdtemp(join(tmpdir(), 'thumble-protocol-mac-'));
let receiver;
function run(command, args) {
  const result = spawnSync(command, args, {encoding: 'utf8'});
  if (result.status !== 0) throw Error(result.stderr || result.stdout);
}
try {
  const contents = join(folder, 'Protocol.app/Contents');
  await mkdir(join(contents, 'MacOS'), {recursive:true});
  await mkdir(join(contents, 'Resources'));
  const key = generateKeyPairSync('ed25519');
  const publicKey = key.publicKey.export({type:'spki',format:'der'}).subarray(-32).toString('base64');
  await writeFile(join(contents, 'Resources/Monetization.json'), JSON.stringify({entitlementPublicKey:publicKey}));
  for (const file of ['BuiltInProfiles.json', 'DesktopKeys.json']) await copyFile(`apps/receiver/Resources/${file}`, join(contents, 'Resources', file));
  await writeFile(join(contents, 'Info.plist'), '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>receiver</string><key>CFBundleIdentifier</key><string>test.thumble.protocol</string></dict></plist>');
  run('xcrun', ['clang','-c','tools/access-receiver-tests/GamepadStub.c','-o',join(folder,'stub.o')]);
  // Keep the production protocol and access checks, but isolate all desktop events.
  const source = await readFile('apps/receiver/Sources/Receiver.swift', 'utf8');
  if (!source.includes('private let desktopOutput = DesktopInput()')) throw Error('Output isolation seam changed');
  await writeFile(join(folder,'Receiver.swift'), source.replace('private let desktopOutput = DesktopInput()', 'private let desktopOutput = DesktopInput(post: { _ in }, trusted: { true })'));
  const sources = (await readdir('apps/receiver/Sources')).filter(n => n.endsWith('.swift') && !['main.swift','Receiver.swift'].includes(n)).map(n => `apps/receiver/Sources/${n}`);
  const binary = join(contents,'MacOS/receiver');
  run('xcrun', ['swiftc','-swift-version','5','-module-cache-path',resolve('build/protocol-swift-cache'),'-import-objc-header','apps/receiver/Sources/Gamepad.h',...sources,join(folder,'Receiver.swift'),'tools/access-receiver-tests/main.swift',join(folder,'stub.o'),'-o',binary]);
  const invitationPath = join(folder,'invitation');
  receiver = spawn(binary, [], {env:{...process.env,TAPPING_PROFILE_DIR:join(folder,'profiles'),TAPPING_TEST_INVITATION:invitationPath,TAPPING_TEST_REPORTS:join(folder,'reports')},stdio:['ignore','ignore','pipe']});
  // Receiver errors may contain private connection details; never echo them.
  receiver.stderr.resume();
  let invitation;
  const deadline = Date.now()+10000;
  while (!invitation && Date.now()<deadline) {
    try { invitation = await readFile(invitationPath,'utf8'); } catch { await new Promise(r => setTimeout(r,25)); }
  }
  if (!invitation) throw Error('Isolated Swift receiver did not start');
  const phone = spawn(process.execPath, ['apps/receiver-desktop/tests/phone-client.mjs'], {stdio:['pipe','inherit','inherit']});
  phone.stdin.end(JSON.stringify({invitation,grantKey:key.privateKey.export({type:'pkcs8',format:'pem'})}));
  const [code] = await once(phone,'exit');
  if (code !== 0) throw Error('Shared phone protocol journey failed against Swift');
  console.log('PASS Swift/Python shared phone protocol contract (captured output only)');
} finally {
  if (receiver && receiver.exitCode === null) { receiver.kill(); await once(receiver,'exit'); }
  await rm(folder,{recursive:true,force:true});
}
