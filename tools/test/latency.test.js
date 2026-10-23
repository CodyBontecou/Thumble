import { test } from 'node:test';
import assert from 'node:assert/strict';
import { LatencyRecorder } from '../../apps/mobile/src/latency-recorder.js';

test('timing recorder separates clock domains and batches bounded duration-only exports', () => {
  const packets = [], recorder = new LatencyRecorder(text => packets.push(JSON.parse(text)));
  for (let i=0;i<20;i++) recorder.record({kind:'touch', js:10, native:1000}, 1012, 25, {timing:{receivedMs:300000, hidMs:300000.2, ackMs:300000.3}});
  assert.equal(packets.length,1); assert.equal(packets[0].rows.length,20);
  assert.deepEqual(packets[0].rows[0],['touch',15,12,.2,.3,3,1000,300000,300000.2,300000.3,1012,'wss']);
  assert.equal(recorder.rows.length,0);
});
test('invalid or reversed timing never becomes a plausible measurement', () => {
  const packets=[], recorder=new LatencyRecorder(text=>packets.push(text));
  recorder.record({kind:'touch',js:0,native:10},9,5,{timing:{receivedMs:0,hidMs:1,ackMs:2}});
  recorder.record({kind:'touch',js:0,native:0},10,10,{timing:{receivedMs:3,hidMs:2,ackMs:4}});
  recorder.record({kind:'touch',js:0,native:0},10,10,{});
  recorder.flush(); assert.equal(packets.length,0);
});
