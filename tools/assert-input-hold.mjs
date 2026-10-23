// Independent signed-receiver HID submission check. Audit is explicitly enabled for QA.
import { readFile, writeFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
const path = process.argv[2], cursor = path + '.cursor';
if (process.argv.includes('--reset')) { await writeFile(cursor, String((await readFile(path, 'utf8')).length)); process.exit(0); }
const offset = Number(await readFile(cursor, 'utf8')), target = Number(process.argv[3] ?? 5000);
const rows = (await readFile(path, 'utf8')).slice(offset).trim().split('\n').filter(Boolean).map(JSON.parse);
assert(rows.length, 'No receiver HID submissions after cursor');
assert(rows.every(r => r.result === 0), 'HID submission failed');
let on = false, start = 0; const holds = [];
for (const row of rows) {
  const pressed = row.report[4] > 0;
  if (pressed && !on) start = row.at;
  if (!pressed && on) holds.push(row.at - start);
  on = pressed;
}
assert.equal(on, false, 'LT remains held');
assert.equal(holds.length, 1, `Expected one uninterrupted LT hold, observed ${JSON.stringify(holds)}`);
assert(holds[0] >= target - 300 && holds[0] <= target + 800, `Unexpected LT duration ${holds[0]} ms for ${target} ms gesture`);
console.log(JSON.stringify({ pass: true, holdMs: holds[0], submissions: rows.length, finalNeutral: rows.at(-1).report.slice(2).every(n => n === 0) }));
assert(rows.at(-1).report.slice(2).every(n => n === 0), 'Other controls remain held');
if (process.argv.includes('--gameplay')) {
  const axis = (r, i) => { const n = r[i] | r[i + 1] << 8; return n > 32767 ? n - 65536 : n; };
  const classify = r => {
    if (r[4]) return 'LT';
    if (r[3] & 16) return 'A';
    const x = axis(r, 6), y = axis(r, 8), rx = axis(r, 10);
    if (Math.max(Math.abs(x), Math.abs(y)) > 1000) return Math.abs(y) >= Math.abs(x) ? (y > 0 ? 'up' : 'down') : (x > 0 ? 'right' : 'left');
    if (Math.abs(rx) > 1000) return rx > 0 ? 'look-right' : 'look-left';
    return '';
  };
  let last = '', began = 0; const runs = [];
  for (const row of rows) {
    const next = classify(row.report);
    if (next !== last) { if (last) runs.push({ control: last, ms: row.at - began }); last = next; began = row.at; }
  }
  const expected = [['LT', 5000], ['up', 2000], ['down', 2000], ['left', 2000], ['right', 2000], ['look-right', 500], ['look-left', 500], ['A', 100]];
  assert.deepEqual(runs.map(r => r.control), expected.map(r => r[0]), `Interrupted or missing control runs: ${JSON.stringify(runs)}`);
  runs.forEach((run, i) => assert(run.ms >= Math.max(20, expected[i][1] - 300) && run.ms <= expected[i][1] + 800, `Unexpected ${run.control} duration ${run.ms}`));
  console.log(JSON.stringify({ gameplayPass: true, runs }));
}
