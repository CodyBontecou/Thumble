import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { createRequire } from 'node:module';
const require=createRequire(import.meta.url);
const sharp=require(process.env.THUMBLE_SHARP_MODULE || '/Users/codybontecou/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/sharp');
const root=path.resolve(import.meta.dirname,'..');
const source=path.join(root,'source');
const output=path.join(root,'exports/en-US/screenshots');
await fs.mkdir(output,{recursive:true});
const W=1206,H=2622;
const esc=s=>s.replaceAll('&','&amp;').replaceAll('<','&lt;');
const svg=(body,bg)=>`<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}"><defs><filter id="shadow" x="-40%" y="-20%" width="180%" height="150%"><feDropShadow dx="0" dy="24" stdDeviation="28" flood-color="#000000" flood-opacity="0.15"/></filter></defs><rect width="${W}" height="${H}" fill="${bg}"/>${body}</svg>`;
const text=(x,y,s,size=105,color='#11110F',weight=700,extra='')=>`<text x="${x}" y="${y}" font-family="Helvetica Neue, Arial, sans-serif" font-size="${size}" font-weight="${weight}" letter-spacing="${size>80?-4:0}" fill="${color}" ${extra}>${esc(s)}</text>`;
const label=(x,y,s,color='#736D63')=>`<text x="${x}" y="${y}" font-family="Menlo, monospace" font-size="28" letter-spacing="3" fill="${color}">${esc(s)}</text>`;
const brand=(color='#11110F',accent='#FF6A00')=>`<rect x="76" y="86" width="22" height="22" rx="5" fill="${accent}"/>${label(118,108,'THUMBLE',color)}`;
let clipID=0;
async function capture(file,x,y,width,radius=70,stroke='#11110F'){
 const bytes=await fs.readFile(path.join(source,'captures',file));const meta=await sharp(bytes).metadata();const height=width*meta.height/meta.width; const id='clip'+(++clipID);
 return `<defs><clipPath id="${id}"><rect x="${x}" y="${y}" width="${width}" height="${height}" rx="${radius}"/></clipPath></defs><rect x="${x-7}" y="${y-7}" width="${width+14}" height="${height+14}" rx="${radius+7}" fill="${stroke}" filter="url(#shadow)"/><image x="${x}" y="${y}" width="${width}" height="${height}" preserveAspectRatio="xMidYMid meet" clip-path="url(#${id})" xlink:href="data:image/png;base64,${bytes.toString('base64')}"/>`;
}
const pages=[
 {file:'01-your-mac-keypad',bg:'#F4EFE5',body:brand()+text(76,280,'Your iPhone.')+text(76,402,'Your Mac keypad.')+text(80,507,'Requires Thumble on your Mac.',38,'#736D63',400)+await capture('ios-everyday.png',163,646,880)},
 {file:'02-shortcuts-within-reach',bg:'#FF6A00',body:brand('#11110F','#11110F')+text(76,280,'Put your shortcuts',103)+text(76,402,'within reach.',103)+text(80,507,'Your daily commands. Ready to tap.',38,'#31220F',400)+await capture('ios-developer.png',163,646,880)},
 {file:'03-make-the-layout-yours',bg:'#1C1D19',body:brand('#F4EFE5')+text(76,280,'Make the',112,'#F4EFE5')+text(76,402,'layout yours.',112,'#F4EFE5')+text(80,507,'Design on Mac. Use on iPhone.',38,'#CAC8BE',400)+label(76,624,'MAC COMPANION','#B4B4A9')+await capture('mac-everyday.png',76,660,1054,22,'#44453E')+label(76,1550,'YOUR','#B4B4A9')+label(76,1596,'IPHONE','#B4B4A9')+`<path d="M80 1640 H208 Q236 1640 236 1668 V1760" fill="none" stroke="#FF6A00" stroke-width="5"/><path d="m221 1745 15 15 15-15" fill="none" stroke="#FF6A00" stroke-width="5"/>`+await capture('ios-everyday.png',374,1160,660,58,'#5C5D54')}
];
const manifest={status:'review-draft',locale:'en-US',width:W,height:H,createdAt:new Date().toISOString(),captureMode:'Real native app captures. iPhone uses saved demo profiles in Practice Mode; Mac uses process-only demo preferences in a disposable app copy. No live Mac input acceptance performed.',pages:[]};
for(const page of pages){
 const vector=svg(page.body,page.bg);await fs.writeFile(path.join(source,page.file+'.svg'),vector);
 const destination=path.join(output,page.file+'.png');await sharp(Buffer.from(vector)).flatten({background:page.bg}).toColourspace('srgb').removeAlpha().png().toFile(destination);
 const data=await fs.readFile(destination);const meta=await sharp(data).metadata();if(meta.width!==W||meta.height!==H||meta.hasAlpha)throw Error('Invalid export '+page.file);
 manifest.pages.push({file:path.relative(root,destination),sha256:crypto.createHash('sha256').update(data).digest('hex'),source:page.file+'.svg'});
}
const thumbs=await Promise.all(pages.map(p=>sharp(path.join(output,p.file+'.png')).resize(362,787,{fit:'contain'}).png().toBuffer()));
await sharp({create:{width:1150,height:835,channels:3,background:'#E8E5DD'}}).composite(thumbs.map((input,i)=>({input,left:20+i*374,top:24}))).png().toFile(path.join(root,'reviews/first-three-contact-sheet.png'));
await fs.writeFile(path.join(root,'reviews/manifest.json'),JSON.stringify(manifest,null,2)+'\n');
console.log('Rendered three opaque 1206 × 2622 PNGs, editable embedded-capture SVGs, and a contact sheet.');
