import test from 'node:test';
import assert from 'node:assert/strict';
import { xboxProfile } from '@tapping/controller';
import { CLOUD_SCOPES, CloudError } from '@tapping/cloud-contracts';
import { callCloudTool, cloudTools, handleMcp, handleProtectedResourceMetadata, MCP_SCOPES } from '../src/mcp.js';

const principal = { kind: 'account', accountId: 'account-a', scopes: CLOUD_SCOPES };
const env = { OAUTH_ISSUER: 'https://identity.example', OAUTH_AUDIENCE: 'https://cloud.example/mcp', OAUTH_JWKS_JSON: '{"keys":[]}' };
const request = () => new Request('https://cloud.example/mcp', { headers: { authorization: 'Bearer account-a-token' } });
const rpc = (method, params, options = {}) => new Request('https://cloud.example/mcp', {
  method: 'POST', headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream', authorization: 'Bearer account-a-token', 'mcp-protocol-version': '2025-11-25', ...options.headers },
  body: JSON.stringify({ jsonrpc: '2.0', ...(options.notification ? {} : { id: 1 }), method, ...(params === undefined ? {} : { params }) }),
});
const deps = { authenticateAccount: async () => principal, handleApi: async () => Response.json({ profiles: [] }) };

test('cloud MCP advertises only scoped controller tools and truthful write hints', () => {
  assert.deepEqual(cloudTools.map(tool => tool.name), ['profile_schema', 'validate_profile', 'list_profiles', 'get_profile', 'save_profile', 'list_devices', 'deliver_profile', 'delivery_status']);
  assert.equal(cloudTools.find(tool => tool.name === 'deliver_profile').annotations.destructiveHint, true);
  assert.equal(cloudTools.find(tool => tool.name === 'save_profile').annotations.readOnlyHint, false);
  assert.ok(cloudTools.every(tool => tool._meta.securitySchemes[0].type === 'oauth2'));
});

test('every tool denies an account without its scope before calling the API', async () => {
  let calls = 0;
  for (const tool of cloudTools) {
    const value = await callCloudTool(request(), env, { ...principal, scopes: [] }, tool.name, {}, async () => { calls++; });
    assert.equal(value.isError, true);
    assert.equal(value.structuredContent.error.code, 'forbidden');
  }
  assert.equal(calls, 0);
});

test('delivery requires exact identifiers and rejects injected account authority', async () => {
  const good = { deviceId: 'phone-1', profileId: 'xbox-standard', profileRevision: 2, requestId: 'request-1' };
  for (const args of [{ ...good, accountId: 'someone-else' }, { ...good, profileRevision: 0 }, { ...good, deviceId: '../other' }, { ...good, requestId: '' }, { profileId: good.profileId, profileRevision: 2 }]) {
    const value = await callCloudTool(request(), env, principal, 'deliver_profile', args, async () => { assert.fail('must reject before API'); });
    assert.equal(value.isError, true);
    assert.equal(value.structuredContent.error.code, 'invalid_request');
  }
});

test('MCP writes pass the original bearer and exact arguments into authenticated REST', async () => {
  const args = { profile: xboxProfile, deviceId: 'phone-1', expectedRevision: 0 };
  const value = await callCloudTool(request(), env, principal, 'save_profile', args, async (forwarded, passedEnv) => {
    assert.equal(forwarded.url, 'https://cloud.example/v1/profiles');
    assert.equal(forwarded.method, 'POST');
    assert.equal(forwarded.headers.get('authorization'), 'Bearer account-a-token');
    assert.equal(passedEnv, env);
    assert.deepEqual(await forwarded.json(), args);
    return Response.json({ profile: xboxProfile, revision: 1, createdAt: '2026-10-23T00:00:00Z' }, { status: 201 });
  });
  assert.equal(value.structuredContent.revision, 1);
  assert.deepEqual(JSON.parse(value.content[0].text), value.structuredContent);
});

test('revision conflicts and validation errors are actionable tool errors', async () => {
  const value = await callCloudTool(request(), env, principal, 'save_profile', { profile: xboxProfile, deviceId: 'phone-1', expectedRevision: 2 }, async () => Response.json({ error: { code: 'revision_conflict', message: 'Read the latest revision.' } }, { status: 409 }));
  assert.equal(value.isError, true);
  assert.equal(value.structuredContent.error.code, 'revision_conflict');
  const validation = await callCloudTool(request(), env, principal, 'validate_profile', { profile: { ...xboxProfile, controls: [] }, deviceId: 'phone-1' }, async forwarded => {
    assert.equal(new URL(forwarded.url).pathname, '/v1/profiles/validate');
    return Response.json({ valid: false, errors: [{ code: 'invalid_profile' }] });
  });
  assert.equal(validation.structuredContent.valid, false);
});

test('stateless SDK HTTP supports initialize, tools/list, call, ping and notifications', async () => {
  const init = await handleMcp(rpc('initialize', { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'test', version: '1' } }), env, deps);
  assert.equal(init.status, 200);
  assert.equal(init.headers.get('mcp-session-id'), null);
  assert.equal((await init.json()).result.protocolVersion, '2025-11-25');
  const list = await handleMcp(rpc('tools/list'), env, deps);
  assert.equal((await list.json()).result.tools.length, 8);
  const call = await handleMcp(rpc('tools/call', { name: 'list_profiles', arguments: {} }), env, deps);
  assert.deepEqual((await call.json()).result.structuredContent, { profiles: [] });
  const ping = await handleMcp(rpc('ping'), env, deps);
  assert.deepEqual((await ping.json()).result, {});
  const notification = await handleMcp(rpc('notifications/initialized', undefined, { notification: true }), env, deps);
  assert.equal(notification.status, 202);
});

test('MCP fails closed, advertises protected resource metadata and blocks unexpected browser origins', async () => {
  const unauthorized = await handleMcp(rpc('tools/list'), env, { authenticateAccount: async () => { throw new CloudError('unauthorized', 'Bad token', 401); } });
  assert.equal(unauthorized.status, 401);
  assert.match(unauthorized.headers.get('www-authenticate'), /oauth-protected-resource\/mcp/);
  const forbidden = await handleMcp(rpc('tools/list', undefined, { headers: { origin: 'https://evil.example' } }), env, deps);
  assert.equal(forbidden.status, 403);
  assert.equal(handleProtectedResourceMetadata(request(), {}).status, 503);
  const metadata = await handleProtectedResourceMetadata(request(), env).json();
  assert.equal(metadata.resource, env.OAUTH_AUDIENCE);
  assert.deepEqual(metadata.authorization_servers, [env.OAUTH_ISSUER]);
});

test('SDK transport rejects malformed messages, oversized streamed bodies and unsupported methods', async () => {
  const headers = { 'content-type': 'application/json', accept: 'application/json, text/event-stream' };
  const malformed = await handleMcp(new Request('https://cloud.example/mcp', { method: 'POST', headers, body: '{' }), env, deps);
  assert.equal(malformed.status, 400);
  const oversized = await handleMcp(rpc('tools/call', { name: 'validate_profile', arguments: { profile: 'x'.repeat(262145) } }), env, deps);
  assert.equal(oversized.status, 413);
  const get = await handleMcp(new Request('https://cloud.example/mcp', { headers: { accept: 'text/event-stream' } }), env, deps);
  assert.equal(get.status, 405);
  const deleted = await handleMcp(new Request('https://cloud.example/mcp', { method: 'DELETE' }), env, deps);
  assert.equal(deleted.status, 405);
  const wrongAccept = await handleMcp(rpc('ping', undefined, { headers: { accept: 'application/json' } }), env, deps);
  assert.equal(wrongAccept.status, 406);
});

test('each stateless MCP request authenticates afresh and concurrent calls stay isolated', async () => {
  let authenticated = 0;
  const overrides = {
    authenticateAccount: async request => {
      authenticated++;
      return { ...principal, accountId: request.headers.get('authorization') };
    },
    handleApi: async request => Response.json({ profiles: [{ id: request.headers.get('authorization') }] }),
  };
  const responses = await Promise.all(['Bearer first', 'Bearer second'].map(authorization => handleMcp(rpc('tools/call', { name: 'list_profiles', arguments: {} }, { headers: { authorization } }), env, overrides)));
  const values = await Promise.all(responses.map(response => response.json()));
  assert.deepEqual(values.map(value => value.result.structuredContent.profiles[0].id), ['Bearer first', 'Bearer second']);
  assert.equal(authenticated, 2);
});

test('Better Auth-only deployments advertise their derived issuer and canonical resource', async () => {
  const hosted = { BETTER_AUTH_URL: 'https://identity.example' };
  const metadata = handleProtectedResourceMetadata(request(), hosted);
  assert.equal(metadata.status, 200);
  const data = await metadata.json();
  assert.equal(data.resource, 'https://identity.example/mcp');
  assert.deepEqual(data.authorization_servers, ['https://identity.example/api/auth']);
  const unauthorized = await handleMcp(new Request('https://alias.example/mcp', { method: 'POST' }), hosted, { authenticateAccount: async () => { throw new CloudError('unauthorized', 'Invalid token', 401); } });
  assert.equal(unauthorized.status, 401);
  assert.equal(unauthorized.headers.get('www-authenticate'), 'Bearer resource_metadata="https://identity.example/.well-known/oauth-protected-resource/mcp"');
});


test('protected resource advertises only scopes used by hosted tools, never device management', async () => {
  const metadata = await handleProtectedResourceMetadata(request(), env).json();
  assert.deepEqual(metadata.scopes_supported, MCP_SCOPES);
  assert.equal(metadata.scopes_supported.includes('devices:manage'), false);
  assert.deepEqual(new Set(metadata.scopes_supported), new Set(cloudTools.flatMap(tool => tool._meta.securitySchemes.flatMap(scheme => scheme.scopes))));
});
