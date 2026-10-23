// Authenticated live test; only neutral reports may be applied. Never logs keys/tokens.
import {readFile} from 'node:fs/promises';
import {createHash,createCipheriv,createDecipheriv,randomBytes} from 'node:crypto';
import {once} from 'node:events';
import dgram from 'node:dgram';
import assert from 'node:assert/strict';
import WebSocket from 'ws';
import {parseInvitation} from '../packages/controller/src/pairing.js';
const path=process.argv[2],sleep=ms=>new Promise(r=>setTimeout(r,ms));
const neutral={buttons:0,lx:0,ly:0,rx:0,ry:0,lt:0,rt:0},aad=Buffer.from('tapping-udp-v1');
async function wait(queue,type,timeout=1500){const until=performance.now()+timeout;while(performance.now()<until){const i=queue.findIndex(m=>m.type===type);if(i>=0)return queue.splice(i,1)[0];await sleep(3);}throw Error('Missing '+type);}
async function connect(){
 const invite=parseInvitation(await readFile(path,'utf8')),messages=[],packets=[];
 const ws=new WebSocket(invite.url,{rejectUnauthorized:false,maxPayload:65536,handshakeTimeout:3000});ws.on('message',d=>messages.push(JSON.parse(d)));await once(ws,'open');
 assert.equal(createHash('sha256').update(ws._socket.getPeerCertificate().raw).digest('hex'),invite.pin);
 ws.send(JSON.stringify({type:'hello',v:3,phoneId:'11111111-1111-1111-1111-111111111111',datagram:1,token:invite.token}));
 let ready=await wait(messages,'ready'),revision=0;
 const offer=await wait(messages,'udp-offer');
 const layout=messages.find(m=>m.type==='layout');if(layout){revision=layout.revision;ws.send(JSON.stringify({type:'layout-ready',revision}));ready=await wait(messages,'paused');}
 const key=Buffer.from(offer.key,'base64'),udp=dgram.createSocket('udp4');udp.on('error',()=>{});await new Promise(r=>udp.connect(offer.port,new URL(invite.url).hostname,r));
 let counter=0n,received=0n;
 function seal(object,overrideKey=key){const nonce=Buffer.alloc(12);nonce.writeUInt32BE(1);nonce.writeBigUInt64BE(++counter,4);const cipher=createCipheriv('aes-256-gcm',overrideKey,nonce);cipher.setAAD(aad);return Buffer.concat([nonce,cipher.update(JSON.stringify(object)),cipher.final(),cipher.getAuthTag()]);}
 udp.on('message',packet=>{try{assert.equal(packet.readUInt32BE(0),2);const n=packet.readBigUInt64BE(4);if(n<=received)return;const decipher=createDecipheriv('aes-256-gcm',key,packet.subarray(0,12));decipher.setAAD(aad);decipher.setAuthTag(packet.subarray(-16));const clear=Buffer.concat([decipher.update(packet.subarray(12,-16)),decipher.final()]);received=n;packets.push(JSON.parse(clear));}catch{}});
 udp.send(seal({type:'probe'}));await wait(packets,'udp-ready');
 const input=(seq,lease=ready.lease,state=neutral)=>({type:'input',seq,lease,revision,state});
 return {ws,udp,seal,packets,messages,input,key,ready,close:async()=>{ws.send(JSON.stringify({type:'bye'}));await once(ws,'close');udp.close();}};
}
let c=await connect();
const forged=c.seal(c.input(1));forged[11]=100;c.udp.send(forged);
c.udp.send(c.seal(c.input(1)));let ack=await wait(c.packets,'ack');assert.equal(ack.seq,1);
console.log('PASS forged counter/tag discarded without advancing replay window; authenticated UDP reaches HID');
const replay=c.seal(c.input(2,ack.lease));c.udp.send(replay);ack=await wait(c.packets,'ack');assert.equal(ack.seq,2);
c.udp.send(replay);await sleep(15);assert(!c.packets.some(m=>m.type==='ack'));
const older=c.seal(c.input(3,ack.lease)),newer=c.seal(c.input(4,ack.lease));c.udp.send(newer);c.udp.send(older);ack=await wait(c.packets,'ack');assert.equal(ack.seq,4);
console.log('PASS replay and reordered older datagrams ignored without disconnecting');
c.udp.send(c.seal(c.input(5,ack.lease),randomBytes(32)));await sleep(15);assert(!c.packets.some(m=>m.type==='ack'));
await sleep(325);const paused=await wait(c.messages,'paused');
c.udp.send(c.seal(c.input(6,ack.lease)));c.udp.send(c.seal(c.input(7,paused.lease,{...neutral,buttons:1})));await sleep(15);assert(!c.packets.some(m=>m.type==='ack'));
c.udp.send(c.seal(c.input(8,paused.lease)));ack=await wait(c.packets,'ack');assert.equal(ack.seq,8);
console.log('PASS wrong key, expired lease and non-neutral recovery rejected; fresh neutral UDP resumes');
const oldKey=c.key;await c.close();await sleep(100);c=await connect();assert(!oldKey.equals(c.key),'Session key was not rotated');
c.udp.send(c.seal(c.input(1),oldKey));await sleep(15);assert(!c.packets.some(m=>m.type==='ack'));
c.udp.send(c.seal(c.input(1)));ack=await wait(c.packets,'ack');assert.equal(ack.seq,1);await c.close();
console.log('PASS disconnect revokes UDP capability; previous-session key cannot control a new session');
