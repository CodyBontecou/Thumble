// Run against a copy of the published Website directory before deploying.
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import sharp from 'sharp';
import { transform } from 'lightningcss';
import { PurgeCSS } from 'purgecss';
const root = process.argv[2];
if (!root) throw new Error('Usage: node tools/website/optimize-lighthouse.mjs /absolute/Website');
const screenshot = '/assets/screenshots/consoleport-circles-78393f9ef12f.png';
const sizes = '(max-width: 640px) calc(100vw - 60px), (max-width: 800px) calc(100vw - 106px), 658px';
async function webp(file, width) {
  const bytes = await sharp(path.join(root, file)).resize({ width, withoutEnlargement: true }).webp({ quality: 85 }).toBuffer();
  const hash = crypto.createHash('sha256').update(bytes).digest('hex').slice(0, 12);
  const dest = file.replace(/\.(png|jpg)$/, `-${width}-${hash}.webp`);
  await fs.writeFile(path.join(root, dest), bytes);
  return dest;
}
const variants = [];
for (const width of [480, 800, 1200, 1800]) variants.push([width, await webp(screenshot, width)]);
async function visit(dir) {
  for (const entry of await fs.readdir(dir, { withFileTypes: true })) {
    const file = path.join(dir, entry.name);
    if (entry.isDirectory()) await visit(file);
    else if (entry.name.endsWith('.html')) {
      let html = await fs.readFile(file, 'utf8');
      html = html.replaceAll(`src="${screenshot}"`, `src="${variants[1][1]}" srcset="${variants.map(([width, url]) => `${url} ${width}w`).join(', ')}" sizes="${sizes}"`);
      const icons = [...new Set([...html.matchAll(/src="(\/assets\/screenshots\/abilities\/[^" ]+\.(?:png|jpg))"/g)].map(match => match[1]))];
      for (const icon of icons) html = html.replaceAll(`src="${icon}"`, `src="${await webp(icon, 128)}"`);
      // Inline each local stylesheet at its original cascade position. Keeping
      // the filename in the marker lets subsequent runs refresh generated CSS.
      const sheets = [...html.matchAll(/<link rel="stylesheet" href="\/(.+?\.css)(?:\?[^"\n]*)?">|<style data-inline-css="([^"]+)">[\s\S]*?<\/style>/g)];
      const landing = dir === root && ['index.html', 'waitlist.html'].includes(entry.name);
      const content = html.replace(/<style[\s\S]*?<\/style>/g, '');
      const behavior = landing ? await fs.readFile(path.join(root, 'script.js'), 'utf8') : '';
      for (const match of sheets) {
        const name = match[1] || match[2];
        if (name.includes('..')) throw new Error('Unexpected CSS path: ' + name);
        let css = await fs.readFile(path.join(root, name));
        if (landing) {
          const [result] = await new PurgeCSS().purge({
            content: [{ raw: content, extension: 'html' }, { raw: behavior, extension: 'js' }],
            css: [{ raw: css.toString() }],
            dynamicAttributes: ['aria-selected', 'aria-disabled', 'data-tone', 'disabled', 'hidden', 'open'],
          });
          css = Buffer.from(result.css);
        }
        const minified = transform({ filename: name, code: css, minify: true }).code.toString();
        html = html.replace(match[0], `<style data-inline-css="${name}">${minified}</style>`);
      }
      html = html.replace('<script src="/config.js"></script>', '<script src="/config.js" defer></script>');
      if (html.includes('<img src="/assets/app-icon.png"')) {
        html = html.replaceAll('<img src="/assets/app-icon.png"', `<img src="${await webp('/assets/app-icon.png', 96)}"`);
      }
      await fs.writeFile(file, html);
    }
  }
}
await visit(root);
console.log('Optimized responsive controller artwork, ability icons, and page CSS.');
