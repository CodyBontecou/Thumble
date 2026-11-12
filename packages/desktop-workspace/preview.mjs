import './build.mjs';
import { build } from 'esbuild';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
const here = path.dirname(fileURLToPath(import.meta.url));
const directory = path.resolve(here, '../../build/desktop-workspace');
await build({ entryPoints: [path.join(here, 'src/preview-host.js')], outfile: path.join(directory, 'preview-host.js'), bundle: true, format: 'iife', target: 'chrome110' });
const allowed = new Map([['/', ['index.html','text/html']], ['/app.js', ['app.js','text/javascript']], ['/preview-host.js', ['preview-host.js','text/javascript']], ['/workspace.css', ['workspace.css','text/css']]]);
const server = createServer(async (req, res) => {
  const item = allowed.get(req.url);
  if (!item) { res.writeHead(404); res.end(); return; }
  let content = await readFile(path.join(directory, item[0]));
  if (item[0] === 'index.html') content = content.toString().replace('bridge-bootstrap.js', 'preview-host.js');
  res.writeHead(200, { 'Content-Type': item[1], 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' }); res.end(content);
});
const port = Number(process.env.THUMBLE_STUDIO_PREVIEW_PORT ?? 4179);
if (!process.argv.includes('--build-only')) server.listen(port, '127.0.0.1', () => console.log(`Simulated desktop workspace: http://127.0.0.1:${port}`));
