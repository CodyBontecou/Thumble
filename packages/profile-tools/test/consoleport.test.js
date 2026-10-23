import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {ProfileStore} from '../src/store.js';
import {importCharacter} from '../src/character-tools.js';
import {mirrorConsolePort,consolePortFrames} from '../src/consoleport.js';
import {modifierPrefix,controlDisplay,neutralState,assertProfile,TouchController} from '../../controller/src/index.js';
const snapshot=JSON.parse(await readFile(new URL('./fixtures/warrior-character.json',import.meta.url)));
const profile=JSON.parse(await readFile(new URL('../../../examples/profiles/warrior.json',import.meta.url)));
const mods=['','SHIFT-','CTRL-','ALT-','CTRL-SHIFT-','ALT-SHIFT-','ALT-CTRL-','ALT-CTRL-SHIFT-'];
test('ConsolePort mirror preserves button arrangement and calibrated sticks, resolves icons, and changes no activation',async t=>{
 const d=await mkdtemp(join(tmpdir(),'cp-mirror-'));t.after(()=>rm(d,{recursive:true,force:true}));const store=new ProfileStore(d);
 const s=structuredClone(snapshot);s.consolePortLayout=['PAD3','PAD4','PADLTRIGGER'].map((key,i)=>({key,frame:{x:.4+i*.1,y:.8,width:.04,height:.06},layers:mods.map(modifier=>({modifier,label:modifier?'Execute':'Charge',command:'ACTIONBUTTON3',kind:'spell',id:modifier?5308:100}))}));
 const p=structuredClone(profile);Object.assign(p.mappings.find(m=>m.controlId==='move'),{outputs:['lx','ly'],invertX:true,invertY:true});await store.save(p,0);await importCharacter(store,JSON.stringify(s));
 const saved=await mirrorConsolePort(store,{snapshotId:s.snapshotId,sourceProfileId:p.id,sourceProfileRevision:1,profileId:'consoleport',expectedRevision:0},async(_,id)=>id===100?'ability_warrior_charge':'ability_warrior_execute');
 assert.equal(saved.profile.controls.find(c=>c.id==='cp-x').icon,'ability_warrior_charge');
 assert.equal(saved.profile.controls.find(c=>c.id==='cp-x').layers['SHIFT-'].icon,'ability_warrior_execute');
 assert.equal(saved.profile.modifiers.shift,'lt');assert.equal((await store.list()).active,null);
 const mapping=saved.profile.mappings.find(m=>m.controlId==='move');assert.deepEqual(mapping.outputs,['lx','ly']);assert.equal(mapping.invertX,true);assert.equal(mapping.invertY,true);
 assert(saved.profile.controls.find(c=>c.id==='cp-x').frame.x<saved.profile.controls.find(c=>c.id==='cp-y').frame.x);
 const touch=new TouchController(saved.profile);const move=saved.profile.controls.find(c=>c.id==='move');touch.down(1,move.frame.x+move.frame.width/2,move.frame.y+.02);assert(touch.snapshot().ly<0);assert.equal(touch.snapshot().ry,0);touch.releaseAll();
});
test('modifier presentation follows held outputs without changing input; rejects unsafe artwork URLs',()=>{
 const p={...profile,modifiers:{shift:'lt',ctrl:'rt',alt:'lb'}};
 const state={...neutralState(),lt:1,rt:1,buttons:1<<4};assert.equal(modifierPrefix(p,state),'ALT-CTRL-SHIFT-');
 assert.equal(modifierPrefix(p,neutralState()),'');
 assert.equal(controlDisplay({label:'Charge',layers:{'SHIFT-':{label:'Execute'}}},'SHIFT-').label,'Execute');
 const trigger={id:'lt',label:'Interact',layers:{'':{label:'Interact'},'SHIFT-':{label:'Unbound'}}};
 assert.equal(controlDisplay(trigger,'SHIFT-',{...p,mappings:[{controlId:'lt',outputs:['lt']}]}).label,'Interact');
 assert.throws(()=>assertProfile({...profile,controls:profile.controls.map(c=>({...c,icon:'https://example.com/tracker'}))}),/icon/);
});

test('phone banks preserve the exported diamonds with large, separate touch targets', () => {
 const buttons = [['PADDUP',.28,.76],['PADDLEFT',.20,.82],['PADDRIGHT',.36,.82],['PADDDOWN',.28,.90],['PAD4',.83,.76],['PAD3',.75,.82],['PAD2',.91,.82],['PAD1',.83,.90],['PADLSHOULDER',.43,.80],['PADLTRIGGER',.38,.85],['PADRSHOULDER',.62,.80],['PADRTRIGGER',.67,.85]].map(([key,x,y])=>({key,frame:{x,y,width:.054,height:.078}}));
 const frames = [...consolePortFrames(buttons).values(), {x:.24,y:.57,width:.20,height:.40}, {x:.56,y:.57,width:.20,height:.40}, {x:.46,y:.72,width:.08,height:.18}];
 for (const f of frames) { assert(Math.min(f.width*780,f.height*280)>=44); assert(f.x>=0 && f.y>=0 && f.x+f.width<=1 && f.y+f.height<=1); }
 for (let i=0;i<frames.length;i++) for (let j=i+1;j<frames.length;j++) { const a=frames[i],b=frames[j]; assert(a.x+a.width<=b.x || b.x+b.width<=a.x || a.y+a.height<=b.y || b.y+b.height<=a.y, `touch regions ${i} and ${j} overlap`); }
});
