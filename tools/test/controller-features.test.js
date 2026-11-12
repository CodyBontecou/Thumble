import test from 'node:test';
import { execFileSync } from 'node:child_process';
import assert from 'node:assert/strict';
import { defaultProfile, consolePortProfile, xboxProfile, validateLayout, aiControllerGeneratorEnabled } from '@tapping/controller';
import { availableProfileTools, callProfileTool } from '../../packages/profile-tools/src/tools.js';
import { availableCloudTools, callCloudTool, handleMcp } from '../../apps/cloud/src/mcp.js';
import { handleApi } from '../../apps/cloud/src/api.js';
import { createTestAuthority, createTestDb, apiRequest } from '../../apps/cloud/test/helpers.js';
import { CLOUD_SCOPES } from '@tapping/cloud-contracts';
import { initialSetup, setupComplete } from '../../apps/mobile/src/onboarding-core.js';
import { Connection } from '../../apps/mobile/src/connection-core.js';

test('generation requires explicit opt-in, and the Xbox layout is the phone default', () => {
  for (const value of [undefined, '', 'false', '1', 'TRUE', true]) assert.equal(aiControllerGeneratorEnabled(value), false);
  assert.equal(aiControllerGeneratorEnabled('true'), true);
  assert.equal(defaultProfile, xboxProfile);
  assert.equal(initialSetup().layoutMode, 'consoleport');
  assert.equal(new Connection({ addListener() {} }).profileSnapshot().profile.id, xboxProfile.id);
  assert.equal(setupComplete({ ...initialSetup(), paired: true, controlsTested: true, wowTested: true }), true);
});

test('ConsolePort touch targets fit compact and large landscape canvases with every gamepad output', () => {
  for (const [width, height] of [[568, 300], [640, 320], [740, 380], [840, 380], [900, 420]]) {
    assert.deepEqual(validateLayout(consolePortProfile, { width, height }).errors, [], `${width} × ${height}`);
    assert.deepEqual(validateLayout(defaultProfile, { width, height }).errors, [], `${width} × ${height}`);
  }
  assert.deepEqual(consolePortProfile.mappings, xboxProfile.mappings.map(mapping => mapping.controlId === 'left-stick' ? { ...mapping, invertY: true } : mapping));
});

test('local MCP hides generation tools and rejects direct calls before touching the store', async () => {
  const enabled = { AI_CONTROLLER_GENERATOR_ENABLED: 'true' };
  const visible = availableProfileTools({}).map(tool => tool.name);
  assert.ok(visible.includes('show_pairing_code'));
  assert.ok(visible.includes('controller_status'));
  const blocked = availableProfileTools(enabled).filter(tool => !visible.includes(tool.name));
  for (const tool of blocked) await assert.rejects(callProfileTool(null, tool.name, {}, {}), /generation is disabled/);
  assert.equal((await callProfileTool({ list: async () => 'readable' }, 'list_profiles', {}, {})), 'readable');
  const profile = { ...structuredClone(defaultProfile), id: 'experiment' };
  assert.equal(await callProfileTool({ save: async value => value.id }, 'save_profile', { profile, expectedRevision: 0 }, enabled), 'experiment');
});

test('cloud MCP hides generation and rejects direct calls with no API side effects', async () => {
  const principal = { kind: 'account', accountId: 'owner', scopes: CLOUD_SCOPES };
  assert.ok(availableCloudTools({}).some(tool => tool.name === 'get_profile'));
  for (const name of ['validate_profile', 'save_profile', 'deliver_profile']) {
    assert.ok(!availableCloudTools({}).some(tool => tool.name === name));
    const result = await callCloudTool(new Request('https://cloud.test/mcp'), {}, principal, name, {}, () => assert.fail('API must not run'));
    assert.equal(result.structuredContent.error.code, 'feature_disabled');
    assert.ok(availableCloudTools({ AI_CONTROLLER_GENERATOR_ENABLED: 'true' }).some(tool => tool.name === name));
  }
  const response = await handleMcp(new Request('https://cloud.test/mcp', {
    method: 'POST', headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list' }),
  }), {}, { authenticateAccount: async () => principal });
  assert.deepEqual((await response.json()).result.tools.map(tool => tool.name), availableCloudTools({}).map(tool => tool.name));
});

test('cloud REST cannot bypass disabled generation, while account access remains available', async t => {
  const authority = await createTestAuthority(), db = createTestDb();
  t.after(() => db.close());
  const env = { ...authority.env, DB: db, AI_CONTROLLER_GENERATOR_ENABLED: 'false' }, token = await authority.token();
  for (const path of ['/profiles', '/profiles/validate', '/deliveries']) {
    const response = await handleApi(apiRequest(path, token, { method: 'POST', body: {} }), env);
    assert.equal(response.status, 403);
    assert.equal((await response.json()).error.code, 'feature_disabled');
  }
  assert.equal((await handleApi(apiRequest('/me', token), env)).status, 200);
  assert.equal(db.sqlite.prepare('SELECT COUNT(*) AS count FROM profile_revisions').get().count, 0);
});

test('mobile opt-in restores the personalization milestone', () => {
  execFileSync(process.execPath, ['--input-type=module', '-e', `
    import assert from 'node:assert/strict';
    import { AI_CONTROLLER_GENERATOR_ENABLED } from './apps/mobile/src/features.js';
    import { initialSetup, setupComplete } from './apps/mobile/src/onboarding-core.js';
    assert.equal(AI_CONTROLLER_GENERATOR_ENABLED, true);
    const setup = { ...initialSetup(), paired: true, controlsTested: true, wowTested: true };
    assert.equal(setupComplete(setup), false);
    assert.equal(setupComplete({ ...setup, personalized: true }), true);
  `], { cwd: new URL('../../', import.meta.url), env: { ...process.env, EXPO_PUBLIC_AI_CONTROLLER_GENERATOR_ENABLED: 'true' }, stdio: 'pipe' });
});
