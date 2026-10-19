import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url);
const sharp=require(process.env.THUMBLE_SHARP_MODULE||'/Users/codybontecou/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/sharp');
const root=path.resolve(import.meta.dirname,'..');const source=path.join(root,'source');const out=path.join(root,'exports/en-US/screenshots');
const W=2622,H=1206;
const esc=s=>s.replaceAll('&','&amp;').replaceAll('<','&lt;');
const text=(x,y,s,size=106,color='#F4ECDD',weight=700)=>`<text x="${x}" y="${y}" font-family="Georgia, serif" font-size="${size}" font-weight="${weight}" letter-spacing="-3" fill="${color}">${esc(s)}</text>`;
const sans=(x,y,s,size=37,color='#BDB8AE',weight=400)=>`<text x="${x}" y="${y}" font-family="Helvetica Neue, Arial, sans-serif" font-size="${size}" font-weight="${weight}" fill="${color}">${esc(s)}</text>`;
const label=(x,y,s,color='#D7B778')=>`<text x="${x}" y="${y}" font-family="Menlo, monospace" font-size="25" letter-spacing="4" fill="${color}">${esc(s)}</text>`;
async function screen(file,x=994,y=330,width=1500){
 const b=await fs.readFile(path.join(source,'captures',file));const m=await sharp(b).metadata();const h=width*m.height/m.width;
 return `<rect x="${x-12}" y="${y-12}" width="${width+24}" height="${h+24}" rx="66" fill="#0D0E10" stroke="#A0804F" stroke-width="2" filter="url(#shadow)"/><defs><clipPath id="screen"><rect x="${x}" y="${y}" width="${width}" height="${h}" rx="54"/></clipPath></defs><image x="${x}" y="${y}" width="${width}" height="${h}" preserveAspectRatio="xMidYMid meet" clip-path="url(#screen)" href="data:image/png;base64,${b.toString('base64')}"/>`;
}
function svg(body,chapter){return `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}"><defs><radialGradient id="ember"><stop stop-color="#68251F" stop-opacity=".75"/><stop offset="1" stop-color="#0B0D10" stop-opacity="0"/></radialGradient><linearGradient id="bg" x2="1" y2="1"><stop stop-color="#151619"/><stop offset="1" stop-color="#080A0D"/></linearGradient><filter id="shadow" x="-25%" y="-45%" width="160%" height="200%"><feDropShadow dx="0" dy="28" stdDeviation="32" flood-color="#000" flood-opacity=".7"/></filter></defs><rect width="${W}" height="${H}" fill="url(#bg)"/><ellipse cx="1810" cy="650" rx="1000" ry="800" fill="url(#ember)"/><g fill="none" stroke="#B18B4B" opacity=".13"><circle cx="1800" cy="635" r="555" stroke-width="1.5"/><circle cx="1800" cy="635" r="590"/><path d="M1800 15V1255M1210 635H2390"/></g><path d="M122 175H825" stroke="#625039" stroke-width="1"/>${label(125,118,'THUMBLE')}${label(990,118,chapter,'#9E9789')}${body}<path d="M125 1080H2495" stroke="#504538"/>${sans(125,1140,'iPhone controller · Requires Thumble on Mac',28,'#A6A198')}${sans(2495,1140,'WoW Forever setup',28,'#D7B778').replace('font-family=','text-anchor="end" font-family=')}</svg>`;}
const controller=await screen('wow-controller-landscape.png');
const picker=await screen('wow-profile-picker-landscape.png');
const pages=[
 {file:'01-iphone-gamepad',chapter:'01 / IPHONE GAMING CONTROLLER',body:text(122,365,'Your iPhone.')+text(122,490,'Your controller.')+sans(128,596,'For your WoW Forever setup.',39)+`<rect x="127" y="682" width="66" height="4" fill="#C99B54"/>`+sans(128,754,'Movement. Camera. Action.',34,'#DDD3C1')+controller},
 {file:'02-move-look-control',chapter:'02 / CONTROLS BUILT FOR PLAY',body:text(122,365,'Move. Look.')+text(122,490,'Take control.')+sans(128,596,'Dual sticks, face buttons',39)+sans(128,651,'and held trigger controls.',39)+label(130,812,'MOVE / LOOK / LT / RT')+controller+`<path d="M1194 1040V1012M1828 1040V1012" stroke="#D7B778" stroke-width="2"/>`+sans(1155,292,'MOVEMENT',23,'#D7B778',500)+sans(1820,292,'CAMERA',23,'#D7B778',500)},
 {file:'03-character-setups',chapter:'03 / YOUR CHARACTERS AND BUILDS',body:text(122,365,'Your character.')+text(122,490,'Your setup.')+sans(128,596,'Create and switch your',39)+sans(128,651,'own controller profiles.',39)+sans(128,791,'Fury Warrior / Frost Mage',34,'#D7B778')+picker}
];
await fs.mkdir(out,{recursive:true});
const manifest={status:'review-draft',direction:'iPhone gaming controller for WoW Forever fans',width:W,height:H,locale:'en-US',createdAt:new Date().toISOString(),captureMode:'Native iPhone simulator screenshots in Practice Mode. Actual canonical wowForever controls. Manually named class profiles; no automatic class or talent detection. Live gamepad acceptance pending.',pages:[]};
for(const p of pages){const v=svg(p.body,p.chapter);await fs.writeFile(path.join(source,p.file+'.svg'),v);const file=path.join(out,p.file+'.png');await sharp(Buffer.from(v)).flatten({background:'#0B0D10'}).toColourspace('srgb').removeAlpha().png().toFile(file);const m=await sharp(file).metadata();if(m.width!==W||m.height!==H||m.hasAlpha)throw Error('Invalid export');manifest.pages.push({file:path.relative(root,file),sha256:crypto.createHash('sha256').update(await fs.readFile(file)).digest('hex')});}
const thumbs=await Promise.all(pages.map(p=>sharp(path.join(out,p.file+'.png')).resize(1049,482).png().toBuffer()));
await sharp({create:{width:1105,height:1534,channels:3,background:'#222322'}}).composite(thumbs.map((input,i)=>({input,left:28,top:28+i*498}))).png().toFile(path.join(root,'reviews/gaming-contact-sheet.png'));
await fs.writeFile(path.join(root,'reviews/manifest.json'),JSON.stringify(manifest,null,2)+'\n');console.log('Rendered three gaming drafts at 2622 × 1206, editable SVGs and contact sheet.');
