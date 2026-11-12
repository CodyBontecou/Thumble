// Regenerate negotiated Markdown from the public HTML whenever website copy changes.
import fs from 'node:fs';
import path from 'node:path';
const root = process.argv[2] || process.cwd();
function decode(text) { return text.replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(+n)).replace(/&#x([0-9a-f]+);/gi, (_, n) => String.fromCodePoint(parseInt(n, 16))).replace(/&(?:amp|lt|gt|quot|apos|nbsp|mdash|ndash|rsquo|lsquo|rarr);/g, value => ({'&amp;':'&','&lt;':'<','&gt;':'>','&quot;':'"','&apos;':"'",'&nbsp;':' ','&mdash;':'—','&ndash;':'–','&rsquo;':'’','&lsquo;':'‘','&rarr;':'→'}[value])); }
function markdown(html, canonicalUrl) {
 let text = html.match(/<main\b[^>]*>([\s\S]*?)<\/main>/i)?.[1] || html;
 // The main reading flow does not need navigation repeated as concatenated links.
 text = text.replace(/<aside\b[^>]*>[\s\S]*?<\/aside>/gi, '');
 text = text.replace(/<nav\b([^>]*)>([\s\S]*?)<\/nav>/gi, (_, attributes, content) => attributes.includes('aria-labelledby="related-guides-title"') ? content : '');
 return decode(text.replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1>/gi,'').replace(/<a\b[^>]*href="([^"]*)"[^>]*>([\s\S]*?)<\/a>/gi,(_,href,label)=>`[${label.replace(/<[^>]*>/g,'').trim()}](${new URL(decode(href),canonicalUrl).href})`).replace(/<table\b[^>]*>([\s\S]*?)<\/table>/gi, (_, table) => {
  const caption = table.match(/<caption\b[^>]*>([\s\S]*?)<\/caption>/i)?.[1] || '';
  const rows = [...table.matchAll(/<tr\b[^>]*>([\s\S]*?)<\/tr>/gi)].map(([, row]) => [...row.matchAll(/<t[hd]\b[^>]*>([\s\S]*?)<\/t[hd]>/gi)].map(([, cell]) => cell.replace(/<[^>]+>/g, '').replace(/\|/g, '&#124;').replace(/\s+/g, ' ').trim()));
  if (!rows.length) return caption;
  return '\n\n'+caption+'\n\n'+rows.map((row, i) => '| '+row.join(' | ')+' |'+(i===0 ? '\n| '+row.map(()=>'---').join(' | ')+' |' : '')).join('\n')+'\n\n';
 }).replace(/<h([1-6])\b[^>]*>/gi,(_,level)=>'\n\n'+'#'.repeat(+level)+' ').replace(/<\/h[1-6]>/gi,'\n\n').replace(/<(?:p|section|article|details|summary|div|ol|ul|pre)\b[^>]*>/gi,'\n\n').replace(/<li\b[^>]*>/gi,'\n- ').replace(/<br\s*\/?>/gi,'\n').replace(/<[^>]+>/g,'')).replace(/[ \t]+/g,' ').replace(/\n +/g,'\n').replace(/\n{3,}/g,'\n\n').trim()+'\n';
}
const pages = {};
// Traverse public content only, not generated assets or function sources.
function htmlFiles(directory, prefix = '') {
 return fs.readdirSync(directory, { withFileTypes: true }).sort((a,b)=>a.name.localeCompare(b.name)).flatMap(entry => {
  const file = path.posix.join(prefix, entry.name);
  if (entry.isDirectory() && (prefix || ['blog', 'guides', 'compare', 'zh-hans'].includes(entry.name))) return htmlFiles(path.join(directory, entry.name), file);
  return entry.isFile() && entry.name.endsWith('.html') && entry.name !== '404.html' ? [file] : [];
 });
}
for (const file of htmlFiles(root)) {
 const route = '/'+file.replace(/(?:^|\/)index\.html$/, '').replace(/\.html$/, '').replace(/\/$/, '');
 if (Object.hasOwn(pages, route)) throw new Error(`Duplicate public Markdown route: ${route}`);
 pages[route]=markdown(fs.readFileSync(path.join(root,file),'utf8'), 'https://thumble.io'+route);
}
fs.writeFileSync(path.join(root,'functions/_markdown.js'), 'export const documents = '+JSON.stringify(pages,null,2)+';\n');
