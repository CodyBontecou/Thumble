import {test} from 'node:test';
import assert from 'node:assert/strict';
import {analyzeClockBounds} from '../network-latency.mjs';
// Mac clock is phone clock + 1000ms, with independently chosen leg delays.
const row=(start,forward,back)=>['heartbeat',forward+back+.2,forward+back+.2,.1,.2,0,start,start+1000+forward,start+1000+forward+.1,start+1000+forward+.2,start+forward+.2+back,'udp'];
test('clock bounds distinguish forward and return spikes without symmetric-delay assumptions',()=>{
 const data=[row(0,2,3),row(100,3,2),row(200,80,3),row(300,2,90)];
 const result=analyzeClockBounds(data,{driftPpm:0}).udp;
 assert.equal(result.invalidBounds,0);
 assert.equal(result.spikesOver40ms.forwardSpikes,1);assert.equal(result.spikesOver40ms.returnSpikes,1);
 assert(result.nativeSendToHidMs.p95Lower>=78);assert(result.nativeSendToHidMs.p95Upper<=82.2);
});
test('inconsistent clocks are reported rather than silently producing a one-way claim',()=>{
 const data=[row(0,2,2),row(100,2,2)]; data[1][7]+=100;data[1][8]+=100;data[1][9]+=100;
 const result=analyzeClockBounds(data,{driftPpm:0}).udp;
 assert.equal(result.invalidBounds,2);assert.equal(result.nativeSendToHidMs.p95Lower,null);
});
