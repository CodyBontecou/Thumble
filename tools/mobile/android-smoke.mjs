import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { parseArgs } from 'node:util';
import { fileURLToPath } from 'node:url';
import { argentTool, assertJourneyReport, assertSmokeReport, fileHash, readJSON, root, run, sameSource, sourceIdentity, writeJSON } from './common.mjs';

export function smokeAndroid({output, device, apk, architecture = 'x86_64', allowDirty = false}) {
  const source = sourceIdentity(!allowDirty);
  if (apk && !allowDirty) throw Error('A prebuilt APK requires --allow-dirty for local QA. CI builds its own artifact.');
  mkdirSync(output, {recursive:true});
  const receipt = path.join(output,'smoke.json');
  rmSync(receipt, {force:true});
  const {devices} = argentTool('list-devices');
  const targets = devices.filter(d => d.platform === 'android' && d.kind === 'emulator' && d.state === 'device' && d.runtimeKind === 'mobile');
  const target = device ? targets.find(d => d.serial === device) : targets.length === 1 ? targets[0] : null;
  if (!target) throw Error('Select a running Android emulator with --device SERIAL. Physical phones are never reset by this check.');
  const temporary = !apk && !allowDirty ? mkdtempSync(path.join(os.tmpdir(),'thumble-android-source-')) : null;
  const checkout = temporary ? path.join(temporary,'source') : root;
  const session = path.join(root,'build/mobile-smoke-session.json');
  mkdirSync(path.dirname(session), {recursive:true});
  writeFileSync(session,'{}',{flag:'wx'});
  try {
    if (!apk) {
      if (!['x86_64','arm64-v8a'].includes(architecture)) throw Error('Unsupported emulator architecture');
      if (temporary) {
        mkdirSync(checkout);
        const archive = path.join(temporary,'source.tar');
        run('git',['archive','--format=tar','--output',archive,source.commit]);
        run('tar',['-xf',archive,'-C',checkout]);
        run('npm',['ci','--no-audit','--no-fund'],{cwd:checkout,log:path.join(output,'install.log')});
      }
      const mobile = path.join(checkout,'apps/mobile');
      run('npx',['--no-install','expo','prebuild','--platform','android','--no-install'],{cwd:mobile,log:path.join(output,'prebuild.log')});
      run(process.platform === 'win32' ? 'gradlew.bat' : './gradlew',[':app:assembleRelease','--no-daemon',`-PreactNativeArchitectures=${architecture}`],{cwd:path.join(mobile,'android'),log:path.join(output,'gradle.log')});
      apk = path.join(mobile,'android/app/build/outputs/apk/release/app-release.apk');
    }
    const apkSha256 = fileHash(apk);
    writeJSON(session,{appPath:apk,udid:target.serial,bundleId:'com.thumble.android'});
    const reports = [];
    argentTool('stop-all-simulator-servers',{devices:[target.serial]});
    for (let pass=1;pass<=2;pass++) {
      const file = path.join(output,`launch-pass-${pass}.json`);
      run('argent',['e2e','run','qa-android-release-launch','--platform','android','--device',target.serial,'--output',path.join(output,'screenshots'),'--json'],{log:file});
      assertSmokeReport(readJSON(file),'qa-android-release-launch');
      reports.push({path:path.basename(file),sha256:fileHash(file)});
    }
    const journeyReports = [];
    const journey = 'qa-setup-before-purchase';
    for (let pass=1;pass<=2;pass++) {
      const file = path.join(output,`journey-pass-${pass}.json`);
      run('argent',['e2e','run',journey,'--platform','android','--device',target.serial,'--output',path.join(output,'screenshots'),'--json'],{log:file});
      assertJourneyReport(readJSON(file),journey);
      journeyReports.push({path:path.basename(file),sha256:fileHash(file)});
    }
    if (fileHash(apk) !== apkSha256) throw Error('APK changed during verification');
    if (!allowDirty) sameSource(source,sourceIdentity());
    writeJSON(receipt,{schemaVersion:1,source,configuration:'Release',platform:'android-emulator',bundleId:'com.thumble.android',apkSha256,
      testSha256:fileHash(path.join(root,'.argent/e2e/qa-android-release-launch.yaml')),reports,journeyReports,
      journeyTestSha256:fileHash(path.join(root,'.argent/e2e',`${journey}.yaml`))});
  } finally {
    rmSync(session,{force:true});
    if (temporary) rmSync(temporary,{recursive:true,force:true});
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const {values} = parseArgs({options:{output:{type:'string',default:path.join(root,'build/android-smoke')},device:{type:'string'},apk:{type:'string'},architecture:{type:'string',default:'x86_64'},'allow-dirty':{type:'boolean',default:false}}});
  smokeAndroid({output:path.resolve(values.output),device:values.device,apk:values.apk && path.resolve(values.apk),architecture:values.architecture,allowDirty:values['allow-dirty']});
}
