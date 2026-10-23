import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { ProfileStore } from '../packages/profile-tools/src/store.js';
import { importCharacter, proposeBindings } from '../packages/profile-tools/src/character-tools.js';
const directory=await mkdtemp(join(tmpdir(),'thumble-addon-test-'));
try {
  const fixture=resolve('packages/profile-tools/test/fixtures/warrior-character.json');
  const store=new ProfileStore(directory);
  const snapshot=await readFile(fixture,'utf8');
  await importCharacter(store,snapshot);
  await store.save(JSON.parse(await readFile('examples/profiles/warrior.json','utf8')),0);
  const result=await proposeBindings(store,{snapshotId:JSON.parse(snapshot).snapshotId,profileId:'warrior',profileRevision:1,intents:[{controlId:'charge',spellId:100},{controlId:'execute',spellId:5308}]});
  const path=join(directory,'plan.json');await writeFile(path,JSON.stringify(result.plan));
  const candidates=[process.env.TAPPING_LUA,'lua5.1','lua',resolve('build/lua/lua-5.1.5/src/lua')].filter(Boolean);
  const executable=candidates.find(command=>spawnSync(command,['-v'],{encoding:'utf8'}).status===0);
  if(!executable)throw Error('Install Lua 5.1 or set TAPPING_LUA to a compatible interpreter, then rerun npm run test:addon.');
  for(const name of ['Codec.lua','Core.lua','WoW.lua','UI.lua']){
    const check=spawnSync(executable,['-e',`assert(loadfile(${JSON.stringify(resolve('addons/ThumbleBridge',name))}))`],{encoding:'utf8'});
    if(check.status!==0)throw Error(check.stderr);
  }
  for (const args of [['addons/test/core.lua',fixture,path,resolve('addons/ThumbleBridge')],['addons/test/wow.lua',resolve('addons/ThumbleBridge')]]) {
    const test=spawnSync(executable,args,{encoding:'utf8'});
    process.stdout.write(test.stdout);process.stderr.write(test.stderr);if(test.status!==0)process.exitCode=1;
  }
}finally{await rm(directory,{recursive:true,force:true});}
