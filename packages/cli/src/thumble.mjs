#!/usr/bin/env node
import { pathToFileURL } from 'node:url';
import { realpathSync } from 'node:fs';

const origin = 'https://thumble.io';
const usage = `Thumble CLI 0.1.0 — read-only service inspection (Node.js 22+)
Usage: thumble <config|sandbox|profiles|profile ID [REVISION]|devices|delivery ID>

config and sandbox need no account or API key.
For account reads, set THUMBLE_ACCESS_TOKEN to an OAuth access token.
Tokens are read only from the environment and sent only to https://thumble.io.
Output is JSON. Failures exit nonzero. No command sends gameplay input.
Docs: https://thumble.io/developers#cli
`;
const validId = value => typeof value === 'string' && /^[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}$/.test(value);
export async function run(args, { fetchImpl = fetch, token = process.env.THUMBLE_ACCESS_TOKEN, out = console.log, err = console.error } = {}) {
  try {
    const [command, id, revision, ...extra] = args;
    if (!command || command === '--help' || command === '-h') { out(usage); return 0; }
    if (command === '--version') { out('0.1.0'); return 0; }
    if (extra.length) throw Error('Too many arguments. Use --help.');
    const paths = { config: '/v1/config', sandbox: '/v1/sandbox', profiles: '/v1/profiles', devices: '/v1/devices' };
    let route = paths[command];
    if (command === 'profile' || command === 'delivery') {
      if (!validId(id) || (command === 'profile' && !/^[a-z0-9][a-z0-9-]{0,63}$/.test(id))) throw Error('Provide a valid record ID.');
      route = `/v1/${command === 'profile' ? 'profiles' : 'deliveries'}/${encodeURIComponent(id)}`;
      if (revision !== undefined) {
        if (command !== 'profile' || !/^[1-9][0-9]*$/.test(revision) || !Number.isSafeInteger(Number(revision))) throw Error('Revision must be a positive safe integer for profile reads only.');
        route += `/revisions/${revision}`;
      }
    } else if (id !== undefined) throw Error('Unexpected argument. Use --help.');
    if (!route) throw Error('Unknown command. Use --help.');
    const isPublic = command === 'config' || command === 'sandbox';
    if (!isPublic && (!token || /\s/.test(token))) throw Error('Set THUMBLE_ACCESS_TOKEN to a valid OAuth access token for account reads.');
    const headers = { accept: 'application/json', ...(!isPublic ? { authorization: `Bearer ${token}` } : {}) };
    let response;
    try { response = await fetchImpl(origin + route, { headers, redirect: 'error', signal: AbortSignal.timeout(15000) }); }
    catch { throw Error('Thumble could not be reached. Check your connection and retry.'); }
    const text = await response.text();
    let body;
    try { body = JSON.parse(text); } catch { throw Error(`Thumble returned a non-JSON response (HTTP ${response.status}).`); }
    if (!response.ok) {
      // Server content is untrusted; never echo it or an OAuth token in failures.
      const recovery = response.status === 401 ? 'Sign in or refresh your OAuth token.' : response.status === 403 ? 'Check the granted read scope.' : response.status === 429 ? 'Wait before retrying.' : 'See the developer documentation.';
      err(JSON.stringify({ error: { code: 'http_error', status: response.status, message: recovery, ...(response.status === 429 ? { retryAfter: response.headers.get('retry-after') } : {}) } }));
      return 1;
    }
    out(JSON.stringify(body, null, 2));
    return 0;
  } catch (error) { err(JSON.stringify({ error: { code: 'cli_error', message: error.message } })); return 1; }
}
if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) process.exitCode = await run(process.argv.slice(2));
