import test from 'node:test';
import assert from 'node:assert/strict';
import { Controller, TouchController, validateProfile } from '../src/index.js';
import { desktopProfile, setChord, issues } from '../../desktop-workspace/src/model.js';

test('portable keyboard chords validate and share held modifier ownership', () => {
  const p=structuredClone(desktopProfile);
  p.controls.push({...p.controls.at(-1),id:'copy'});
  p.mappings.push({controlId:'copy',outputs:['key:ControlLeft','key:KeyC']});
  p.mappings.at(-2).outputs=['key:ControlLeft','key:KeyA'];
  const c=new Controller(p);
  c.update('space',true);c.update('copy',true);
  assert.deepEqual(c.snapshot().desktop.keys,['key:ControlLeft','key:KeyA','key:KeyC']);
  assert.deepEqual(c.update('space',false).desktop.keys,['key:ControlLeft','key:KeyC']);
  assert.deepEqual(c.releaseAll(),{buttons:0,lx:0,ly:0,rx:0,ry:0,lt:0,rt:0});
  assert.equal(issues(desktopProfile).length,0);
  assert.throws(()=>setChord(desktopProfile,'space',['key:ShellCommand']));
  assert.ok(validateProfile({...p,mappings:p.mappings.map(m=>m.controlId==='copy'?{...m,outputs:['key:KeyA','key:KeyA']}:m)}).length);
});

test('trackpad uses relative motion and two-finger scroll without jumps on finger changes', () => {
  const c=new TouchController(desktopProfile);c.setViewport(844,390);
  c.down(1,.5,.5);c.move(1,.6,.55);
  assert.ok(Math.abs(c.snapshot().desktop.x-84.4)<.001);
  c.down(2,.7,.6);const x=c.snapshot().desktop.x;
  c.move(1,.6,.65);c.move(2,.7,.7);
  assert.equal(c.snapshot().desktop.x,x);
  assert.ok(c.snapshot().desktop.scrollY>1);
  c.up(2);c.move(1,.61,.65);
  assert.ok(Math.abs(c.snapshot().desktop.x-x-8.44)<.001);
  const before=c.snapshot().desktop.x;c.up(1);
  assert.equal(c.snapshot().desktop.x,before);
  c.releaseAll();assert.equal(c.snapshot().desktop.x,0);
});

test('mouse drag state and multiple fingers release only their own source', () => {
  const c=new TouchController(desktopProfile);c.setViewport(844,390);
  c.down(1,.1,.5);c.down(2,.1,.5);c.up(1);
  assert.equal(c.snapshot().desktop.buttons,1);
  c.down(3,.5,.5);c.move(3,.6,.5);
  assert.equal(c.snapshot().desktop.buttons,1);
  c.up(2);assert.equal(c.snapshot().desktop.buttons,0);
});
