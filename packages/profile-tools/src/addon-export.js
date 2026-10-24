import { readFile, realpath, stat } from 'node:fs/promises';
import { basename, dirname } from 'node:path';
import { importCharacter, importBindingResult } from './character-tools.js';

/** Reads a single serialized Lua string. Never evaluates a SavedVariables file. */
export function extractAddonExport(source, field) {
  if (!['exportText', 'receiptText'].includes(field) || !/^\s*ThumbleBridgeDB\s*=\s*\{/.test(source)) throw Error('Not a Thumble SavedVariables file');
  const match = new RegExp('\\["' + field + '"\\]\\s*=\\s*').exec(source);
  if (!match) throw Error(`No ${field} saved. Click Export in-game, then /reload or log out so WoW writes SavedVariables.`);
  let position = match.index + match[0].length;
  const delimiter = source[position++];
  if (delimiter !== '"') throw Error('Unsupported SavedVariables string format');
  const chunks = [], escapes = { a: 7, b: 8, f: 12, n: 10, r: 13, t: 9, v: 11, '\\': 92, '"': 34, "'": 39 };
  let size = 0, start = position;
  const append = chunk => { size += chunk.length; if (size > 262144) throw Error('Addon export exceeds 256 KiB'); chunks.push(chunk); };
  while (position < source.length) {
    const char = source[position++];
    if (char === delimiter) { append(Buffer.from(source.slice(start, position - 1))); return Buffer.concat(chunks).toString('utf8'); }
    if (char === '\n' || char === '\r') throw Error('Invalid SavedVariables string');
    if (char !== '\\') continue;
    append(Buffer.from(source.slice(start, position - 1)));
    const escape = source[position++];
    if (/\d/.test(escape ?? '')) {
      let digits = escape;
      while (digits.length < 3 && /\d/.test(source[position] ?? '')) digits += source[position++];
      const byte = Number(digits); if (byte > 255) throw Error('Invalid Lua byte escape'); append(Buffer.from([byte]));
    } else if (Object.hasOwn(escapes, escape)) append(Buffer.from([escapes[escape]]));
    else throw Error('Unsupported Lua string escape');
    start = position;
  }
  throw Error('Unterminated SavedVariables string');
}
export async function readAddonExport(store, savedVariablesPath, kind) {
  if (typeof savedVariablesPath !== 'string' || !['character', 'result'].includes(kind)) throw Error('Provide a ThumbleBridge.lua SavedVariables path and exportKind character or result');
  const path = await realpath(savedVariablesPath);
  if (basename(path) !== 'ThumbleBridge.lua' || basename(dirname(path)) !== 'SavedVariables') throw Error('Only SavedVariables/ThumbleBridge.lua exports can be read');
  if ((await stat(path)).size > 4 * 1024 * 1024) throw Error('SavedVariables file exceeds 4 MiB');
  const source = await readFile(path, 'utf8');
  const exportText = extractAddonExport(source, kind === 'character' ? 'exportText' : 'receiptText');
  return kind === 'character' ? importCharacter(store, exportText) : importBindingResult(store, exportText);
}
