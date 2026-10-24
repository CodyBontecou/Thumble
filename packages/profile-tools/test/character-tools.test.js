process.env.AI_CONTROLLER_GENERATOR_ENABLED = 'true';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ProfileStore } from '../src/store.js';
import { callProfileTool } from '../src/tools.js';
const fixture = JSON.parse(await readFile(new URL('./fixtures/warrior-character.json', import.meta.url)));
const warrior = JSON.parse(await readFile(new URL('../../../examples/profiles/warrior.json', import.meta.url)));
async function setup(t, snapshot = structuredClone(fixture)) {
  const directory = await mkdtemp(join(tmpdir(), 'thumble-character-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const store = new ProfileStore(directory);
  await store.save(warrior, 0);
  const call = (name, args) => callProfileTool(store, name, args);
  await call('import_character', { exportText: JSON.stringify(snapshot) });
  const propose = extra => call('propose_bindings', { snapshotId: snapshot.snapshotId, profileId: warrior.id, profileRevision: 1, ...extra });
  return { store, call, propose, snapshot };
}
function receipt({plan,preview}) {
  return {status:'verified',bridgeVersion:1,kind:'binding-receipt',planId:plan.id,snapshotId:plan.snapshotId,characterGuid:plan.characterGuid,bindingSet:plan.bindingSet,profile:plan.profile,appliedAt:1792780010,results:preview.map(row=>({key:row.key,controlId:row.controlId,command:row.after,base:row.after,effective:row.after}))};
}
test('import reads learned spells and automatic proposals map profile outputs to WoW keys without changing the profile', async t => {
  const h = await setup(t), result = await h.propose();
  assert.equal(result.plan.kind, 'binding-plan');
  assert.deepEqual(result.plan.changes.find(change => change.controlId === 'charge'), {controlId:'charge',label:'Charge',key:'PAD3',expectedBase:'ACTIONBUTTON3',expectedEffective:'ACTIONBUTTON3',spellId:100});
  assert.equal(result.plan.changes.find(change => change.controlId === 'execute').spellId, 5308);
  assert.equal(result.plan.changes.find(change => change.controlId === 'chat').action, 'OPENCHAT');
  assert.equal((await h.store.get('warrior')).revision, 1);
  assert.equal((await h.store.list()).active, null);
  assert.equal((await h.call('get_character', {snapshotId:fixture.snapshotId})).spells.length, 4);
  assert.equal((await h.call('get_binding_plan', {planId:result.plan.id})).plan.id, result.plan.id);
});
test('unlearned and ambiguous spells remain unresolved instead of fabricating abilities', async t => {
  const snapshot = structuredClone(fixture);
  snapshot.spells = snapshot.spells.filter(spell=>spell.name!=='Execute');
  snapshot.spells.push({id:6178,name:'Charge',rank:'Rank 2',passive:false});
  const h = await setup(t,snapshot), result = await h.propose();
  assert(result.unresolved.some(item=>item.controlId==='execute'));
  assert(result.unresolved.some(item=>item.controlId==='charge' && item.reason.includes('ranks')));
  assert(!result.plan.changes.some(item=>item.controlId==='charge'||item.controlId==='execute'));
  await assert.rejects(h.propose({intents:[{controlId:'execute',spellId:5308}]}),/not an available learned spell/);
});
test('explicit proposals reject passive spells, macros, duplicate keys, modifiers and overrides', async t => {
  const h=await setup(t);
  await assert.rejects(h.propose({intents:[{controlId:'charge',spellId:20572}]}),/not an available/);
  await assert.rejects(h.propose({intents:[{controlId:'charge',action:'MACRO /cast Execute'}]}),/supported utility/);
  await assert.rejects(h.propose({intents:[{controlId:'lt',spellId:100}]}),/reserved/);
  await assert.rejects(h.propose({intents:[{controlId:'charge',spellId:100},{controlId:'charge',spellId:78}]}),/duplicate/);
  const snapshot=structuredClone(fixture);snapshot.snapshotId+='new';snapshot.bindings.find(item=>item.key==='PAD3').effective='CLICK Override:LeftButton';
  await h.call('import_character',{exportText:JSON.stringify(snapshot)});
  await assert.rejects(h.propose({snapshotId:snapshot.snapshotId,intents:[{controlId:'charge',spellId:100}]}),/override/);
});
test('result confirmation is exact and labels require the original unchanged profile revision', async t => {
  const h=await setup(t), result=await h.propose({intents:[{controlId:'charge',spellId:78}]});
  await assert.rejects(h.call('sync_binding_labels',{planId:result.plan.id,expectedRevision:1}),/confirmed addon result/);
  const bad=receipt(result);bad.results[0].effective='';
  await assert.rejects(h.call('import_binding_result',{exportText:JSON.stringify(bad)}),/unconfirmed/);
  const good=receipt(result);
  assert.equal((await h.call('import_binding_result',{exportText:JSON.stringify(good)})).status,'receipt-confirmed');
  const synced=await h.call('sync_binding_labels',{planId:result.plan.id,expectedRevision:1});
  assert.equal(synced.revision,2);assert.equal(synced.profile.controls.find(c=>c.id==='charge').label,'Heroic Strike');
  assert.equal((await h.store.list()).active,null);
  await assert.rejects(h.call('sync_binding_labels',{planId:result.plan.id,expectedRevision:2}),/changed after the proposal/);
});
test('results for another character, plan or duplicated key cannot confirm a proposal',async t=>{
  const h=await setup(t), result=await h.propose();
  for(const mutate of [r=>r.characterGuid='other',r=>r.profile.revision=2,r=>r.results[1]=r.results[0],r=>r.results.pop()]){
    const candidate=structuredClone(receipt(result));mutate(candidate);
    await assert.rejects(h.call('import_binding_result',{exportText:JSON.stringify(candidate)}));
  }
});
test('malformed or conflicting character snapshots never replace a prior export', async t => {
  const h=await setup(t);
  for(const candidate of [null,{}, {...fixture,spells:[{id:1,name:'Injected|script',passive:false}]}, {...fixture,bindings:[]}]){
    await assert.rejects(h.call('import_character',{exportText:JSON.stringify(candidate)}));
  }
  await assert.rejects(h.call('import_character',{exportText:JSON.stringify({...fixture,build:'different'})}),/different contents/);
  assert.equal((await h.call('list_characters',{})).length,1);
});

test('recognized ConsolePort action proxies can be proposed, but pending receipts cannot confirm them', async t=>{
  const snapshot=structuredClone(fixture), binding=snapshot.bindings.find(item=>item.key==='PAD3');
  binding.effective='CLICK CPB_PAD3:ControllerInput';binding.consolePortProxy=true;
  const h=await setup(t,snapshot), result=await h.propose({intents:[{controlId:'charge',spellId:100}]});
  assert.equal(result.plan.changes[0].expectedEffective,binding.effective);
  const pending=receipt(result);pending.status='pending';
  await assert.rejects(h.call('import_binding_result',{exportText:JSON.stringify(pending)}),/Invalid binding result/);
});
