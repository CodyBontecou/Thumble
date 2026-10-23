import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { extractAddonExport, readAddonExport } from '../src/addon-export.js';
import { ProfileStore } from '../src/store.js';
const literal = value => JSON.stringify(value).replace(/\\u([0-9a-f]{4})/gi, (_, code) => String.fromCharCode(parseInt(code,16)));
test('SavedVariables extraction decodes only strings and never evaluates Lua', () => {
  const json='{"name":"Crème 🚀","line":"a\\nb"}';
  const source='\nThumbleBridgeDB = { ["exportText"] = '+literal(json)+', ["evil"] = os.execute("never run") }';
  assert.equal(extractAddonExport(source,'exportText'),json);
  assert.equal(extractAddonExport('ThumbleBridgeDB = {["exportText"] = "\\123\\125"}','exportText'),'{}');
  for (const source of ['OtherDB = {}','ThumbleBridgeDB = {["exportText"] = loadstring("bad")}','ThumbleBridgeDB = {["exportText"] = "unterminated','ThumbleBridgeDB = {["exportText"] = "\\999"}']) assert.throws(()=>extractAddonExport(source,'exportText'));
});
test('disk import accepts only the named addon SavedVariables file',async t=>{
  const directory=await mkdtemp(join(tmpdir(),'thumble-addon-export-'));t.after(()=>rm(directory,{recursive:true,force:true}));
  const store=new ProfileStore(join(directory,'profiles'));
  const folder=join(directory,'SavedVariables');await mkdir(folder);
  const snapshot=await readFile(new URL('./fixtures/warrior-character.json',import.meta.url),'utf8');
  const path=join(folder,'ThumbleBridge.lua');
  await writeFile(path,'ThumbleBridgeDB = {["exportText"] = '+literal(snapshot)+'}');
  assert.equal((await readAddonExport(store,path,'character')).character.name,'Testwarrior');
  const other=join(folder,'Other.lua');await writeFile(other,'ThumbleBridgeDB = {}');
  await assert.rejects(readAddonExport(store,other,'character'),/Only SavedVariables/);
  await assert.rejects(readAddonExport(store,path,'result'),/No receiptText saved/);
});
