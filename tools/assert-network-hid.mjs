import {readFile,writeFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
const log=new URL('../build/network-hid.log',import.meta.url),cursor=new URL('../build/network-hid-cursor',import.meta.url);
if(process.argv.includes('--reset')) {const data=await readFile(log,'utf8');await writeFile(cursor,String(data.length));process.exit(0);}
const offset=Number(await readFile(cursor,'utf8'));
const deadline=performance.now()+1000;
while(performance.now()<deadline){
 const data=await readFile(log,'utf8');const lines=data.slice(offset).trim().split('\n').filter(line=>line.startsWith('L '));
 const pressed=lines.some(line=>/ LT 1\.000 /.test(line));
 const last=lines.at(-1);const values=last?.match(/-?\d+(?:\.\d+)?/g)?.map(Number);
 if(pressed&&values?.length===14&&values.every(value=>value===0)){await writeFile(cursor,String(data.length));console.log('PASS independent HID LT press then full neutral');process.exit(0);}
 await new Promise(r=>setTimeout(r,10));
}
assert.fail('Independent HID observer did not see LT=1 followed by full neutral after this gesture');
