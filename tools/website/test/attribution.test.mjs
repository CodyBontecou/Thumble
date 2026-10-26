import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { normalizeAttribution, captureAttribution } from '../../../apps/website/attribution.mjs';
import { onRequest } from '../../../apps/website/functions/api/subscribe.js';

const schema = fs.readFileSync(new URL('../../../apps/website/schema.sql', import.meta.url), 'utf8');
const migration = fs.readFileSync(new URL('../../../apps/website/migrations/0001_waitlist_attribution.sql', import.meta.url), 'utf8');
function database() {
  const sql = new DatabaseSync(':memory:');
  sql.exec('PRAGMA foreign_keys = ON');
  sql.exec(schema);
  sql.exec(migration); // Reapplying the additive migration must be harmless.
  return { sql, prepare(query) { return { bind(...values) { return { query, values }; } }; }, async batch(statements) {
    sql.exec('BEGIN');
    try { const result = statements.map(({query,values})=>sql.prepare(query).run(...values)); sql.exec('COMMIT'); return result; }
    catch (error) { sql.exec('ROLLBACK'); throw error; }
  } };
}
function request(body, contentType='application/json') {
  return new Request('https://thumble.io/api/subscribe',{method:'POST',headers:{'Content-Type':contentType,'Accept':'application/json'},body:contentType==='application/json'?JSON.stringify(body):new URLSearchParams(body)});
}
const signup = {email:'test@example.com',consent:true,source:'guide-wow-controller-mac'};

test('navigation keeps first landing while dropping unknown campaign values and private URL data', () => {
  const memory = new Map();
  const storage = {getItem:key=>memory.get(key),setItem:(key,value)=>memory.set(key,value)};
  captureAttribution('https://thumble.io/guides/wow-controller-mac?utm_source=google&utm_medium=organic&token=private#secret', storage);
  const result = captureAttribution('https://thumble.io/waitlist?email=test@example.com&utm_campaign=private-token',storage);
  assert.deepEqual(result,{first:{landing:'/guides/wow-controller-mac',utm_source:'google',utm_medium:'organic'},latest:{landing:'/waitlist'}});
  assert.ok(!JSON.stringify([...memory.values()]).includes('private'));
  assert.ok(!JSON.stringify([...memory.values()]).includes('test@example.com'));
  assert.equal(captureAttribution('https://thumble.io/docs.html', {getItem(){throw Error('Blocked');},setItem(){throw Error('Blocked');}}).first.landing,'/docs');
  assert.deepEqual(normalizeAttribution({first:{landing:'/private/profile/1',utm_source:'google&token=secret',email:'private'}}),{first:{landing:'unknown'},latest:{landing:'unknown'}});
});

test('repeat signups retain first tracked source and landing while updating latest attribution atomically', async () => {
  const DB=database();
  try {
    const first = {first:{landing:'/guides/wow-controller-mac',utm_source:'google'},latest:{landing:'/waitlist'}};
    assert.equal((await onRequest({request:request({...signup,attribution:first}),env:{DB}})).status,200);
    assert.equal((await onRequest({request:request({...signup,source:'guide-thumble-phone-mac-pairing',attribution:{first:{landing:'/'},latest:{landing:'/guides/thumble-phone-mac-pairing'}}}),env:{DB}})).status,200);
    const row=DB.sql.prepare('SELECT * FROM waitlist_attribution').get();
    assert.equal(row.first_source,signup.source);
    assert.equal(row.latest_source,'guide-thumble-phone-mac-pairing');
    assert.deepEqual(JSON.parse(row.first_touch),first.first);
    assert.deepEqual(JSON.parse(row.latest_touch),{landing:'/guides/thumble-phone-mac-pairing'});
    assert.equal(DB.sql.prepare('SELECT count(*) n FROM waitlist_subscribers').get().n,1);
    DB.sql.prepare('DELETE FROM waitlist_subscribers').run();
    assert.equal(DB.sql.prepare('SELECT count(*) n FROM waitlist_attribution').get().n,0);
  } finally {DB.sql.close();}
});

test('existing subscribers and native form submissions work without inventing prior visit data', async () => {
  const DB=database();
  try {
    DB.sql.exec("INSERT INTO waitlist_subscribers (email,status,source,consent_text,consented_at,created_at,updated_at) VALUES ('test@example.com','subscribed','historic','consent','old','old','old')");
    const response=await onRequest({request:request({...signup,consent:'true'},'application/x-www-form-urlencoded'),env:{DB}});
    assert.equal(response.status,200);
    assert.deepEqual(JSON.parse(DB.sql.prepare('SELECT first_touch FROM waitlist_attribution').get().first_touch),{landing:'unknown'});
    assert.equal(DB.sql.prepare('SELECT created_at FROM waitlist_subscribers').get().created_at,'old');
  } finally {DB.sql.close();}
});

test('validation, missing consent, honeypots and missing Turnstile token never write subscribers', async () => {
  const DB=database();
  try {
    assert.equal((await onRequest({request:request(null),env:{DB}})).status,400);
    assert.equal((await onRequest({request:request({...signup,email:'invalid'}),env:{DB}})).status,422);
    assert.equal((await onRequest({request:request({...signup,consent:false}),env:{DB}})).status,422);
    assert.equal((await onRequest({request:request({...signup,company:'bot'}),env:{DB}})).status,200);
    assert.equal((await onRequest({request:request(signup),env:{DB,TURNSTILE_SECRET_KEY:'test-only'}})).status,403);
    assert.equal(DB.sql.prepare('SELECT count(*) n FROM waitlist_subscribers').get().n,0);
    assert.equal(DB.sql.prepare('SELECT count(*) n FROM waitlist_attribution').get().n,0);
  } finally {DB.sql.close();}
});

test('missing migration rolls back the subscriber insert instead of reporting an unrecorded success', async () => {
  const DB=database();
  try {
    DB.sql.exec('DROP TABLE waitlist_attribution');
    const previous=console.error;console.error=()=>{};
    let response;
    try {response=await onRequest({request:request(signup),env:{DB}});} finally {console.error=previous;}
    assert.equal(response.status,500);
    assert.equal(DB.sql.prepare('SELECT count(*) n FROM waitlist_subscribers').get().n,0);
  } finally {DB.sql.close();}
});
