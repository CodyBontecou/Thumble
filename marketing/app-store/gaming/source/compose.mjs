import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url);
const sharp=require(process.env.THUMBLE_SHARP_MODULE||'/Users/codybontecou/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/sharp');
const root=path.resolve(import.meta.dirname,'..');const source=path.join(root,'source');const out=path.join(root,'exports/en-US/screenshots');
const W=1206,H=2622,packageHash='31c400f4bd0468019100e2e7450e9a375ae05c9e51d05353e058f287c1a6850a';
const esc=s=>s.replaceAll('&','&amp;').replaceAll('<','&lt;');
const heading=(y,s,size=99)=>`<text x="78" y="${y}" font-family="Georgia, serif" font-size="${size}" font-weight="700" letter-spacing="-3" fill="#F4ECDD">${esc(s)}</text>`;
const sans=(x,y,s,size=36,color='#BDB8AE')=>`<text x="${x}" y="${y}" font-family="Helvetica Neue, Arial, sans-serif" font-size="${size}" fill="${color}">${esc(s)}</text>`;
const label=(x,y,s,color='#D7B778')=>`<text x="${x}" y="${y}" font-family="Menlo, monospace" font-size="25" letter-spacing="3" fill="${color}">${esc(s)}</text>`;
async function screen(file,x=163,y=620,width=880){
 const b=await fs.readFile(path.join(source,'captures',file));const m=await sharp(b).metadata();if(m.width>=m.height)throw Error('Portrait native capture required');const h=width*m.height/m.width;
 return `<rect x="${x-9}" y="${y-9}" width="${width+18}" height="${h+18}" rx="72" fill="#0D0E10" stroke="#806547" stroke-width="2" filter="url(#shadow)"/><defs><clipPath id="screen"><rect x="${x}" y="${y}" width="${width}" height="${h}" rx="63"/></clipPath></defs><image x="${x}" y="${y}" width="${width}" height="${h}" preserveAspectRatio="xMidYMid meet" clip-path="url(#screen)" href="data:image/png;base64,${b.toString('base64')}"/>`;
}
function svg(body,n){return `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}"><defs><radialGradient id="ember"><stop stop-color="#762724" stop-opacity=".56"/><stop offset="1" stop-color="#0B0D10" stop-opacity="0"/></radialGradient><linearGradient id="bg" x2="1" y2="1"><stop stop-color="#191A1D"/><stop offset="1" stop-color="#080A0D"/></linearGradient><filter id="shadow" x="-25%" y="-10%" width="160%" height="130%"><feDropShadow dx="0" dy="24" stdDeviation="30" flood-color="#000" flood-opacity=".6"/></filter></defs><rect width="${W}" height="${H}" fill="url(#bg)"/><ellipse cx="760" cy="1900" rx="850" ry="1100" fill="url(#ember)"/><path d="M78 145H1128" stroke="#504538"/>${label(78,106,'THUMBLE')}${label(1080,106,n,'#827A6D')}${body}</svg>`;}
const controller=await screen('fury-forge-portrait.png');const picker=await screen('fury-forge-profile-picker-portrait.png');
const pages=[
 {file:'01-iphone-gamepad',body:heading(275,'Your iPhone.')+heading(397,'Your controller.')+sans(82,487,'For your WoW Forever setup.',39)+sans(82,553,'Requires Thumble on Mac.',29,'#A6A198')+controller},
 {file:'02-move-look-control',body:heading(275,'Fury at your')+heading(397,'fingertips.')+sans(82,487,'Bloodthirst. Whirlwind. Execute. Cleave.',32)+sans(82,553,'Fury Forge · Warrior icon layout',29,'#D7B778')+controller},
 {file:'03-character-setups',body:heading(275,'Your Warrior.')+heading(397,'Your setup.')+sans(82,487,'Create and switch controller profiles.',36)+sans(82,553,'Fury Warrior / Solo / Group',29,'#D7B778')+picker}
];
await fs.mkdir(out,{recursive:true});
const manifest={status:'review-draft',direction:'Portrait iPhone gaming controller for WoW Forever fans using existing Fury Forge',width:W,height:H,locale:'en-US',createdAt:new Date().toISOString(),skin:{identifier:'com.thumble.fury-forge',version:'1.0.0',packageSHA256:packageHash,humanApproval:'pending and unchanged'},captureMode:'Real native portrait iPhone captures in Practice Mode. Unchanged Fury Forge package; manually named Fury profiles. Ability pictures are suggested action-bar placements, not automatic spell synchronization. Live gameplay acceptance pending.',captures:[],pages:[]};
for(const file of ['fury-forge-portrait.png','fury-forge-profile-picker-portrait.png']){const bytes=await fs.readFile(path.join(source,'captures',file));manifest.captures.push({file:'source/captures/'+file,sha256:crypto.createHash('sha256').update(bytes).digest('hex')});}
for(const p of pages){const v=svg(p.body,p.file.slice(0,2));await fs.writeFile(path.join(source,p.file+'.svg'),v);const file=path.join(out,p.file+'.png');await sharp(Buffer.from(v)).flatten({background:'#0B0D10'}).toColourspace('srgb').removeAlpha().png().toFile(file);const m=await sharp(file).metadata();if(m.width!==W||m.height!==H||m.hasAlpha)throw Error('Invalid export');manifest.pages.push({file:path.relative(root,file),sha256:crypto.createHash('sha256').update(await fs.readFile(file)).digest('hex')});}
const thumbs=await Promise.all(pages.map(p=>sharp(path.join(out,p.file+'.png')).resize(362,787).png().toBuffer()));
await sharp({create:{width:1150,height:835,channels:3,background:'#222322'}}).composite(thumbs.map((input,i)=>({input,left:20+i*374,top:24}))).png().toFile(path.join(root,'reviews/gaming-contact-sheet.png'));
await fs.writeFile(path.join(root,'reviews/manifest.json'),JSON.stringify(manifest,null,2)+'\n');console.log('Rendered three Fury Forge portrait drafts at 1206 × 2622.');
