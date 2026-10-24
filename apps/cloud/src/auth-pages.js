import { verifyOAuthQueryParams } from '@better-auth/oauth-provider';
import { createIdentity, identityConfig } from './identity.js';

const descriptions = {
  openid: 'Identify your Thumble account', profile: 'Read your account name', email: 'Read your email address',
  offline_access: 'Stay connected until you revoke access',
  'profiles:read': 'Read your saved controllers', 'profiles:write': 'Create controller revisions',
  'devices:read': 'Read your registered phones', 'devices:manage': 'Register and disconnect phones',
  'deliveries:write': 'Send saved controller revisions to your phones', 'deliveries:read': 'Read phone delivery receipts',
  'pairing:read': 'Read pairing QR codes that you explicitly share from your Mac', 'pairing:manage': 'Share this Mac’s temporary pairing QR with your Thumble account for up to ten minutes',
};
const escape = value => String(value ?? '').replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char]));
const scriptValue = value => JSON.stringify(value).replace(/</g, '\\u003c').replace(/\u2028/g, '\\u2028').replace(/\u2029/g, '\\u2029');
const css = `:root{color-scheme:dark;font:17px/1.5 system-ui,sans-serif;background:#111310;color:#f4f4ed}*{box-sizing:border-box}body{margin:0;padding:48px 20px;min-height:100dvh;display:grid;place-items:center}main{width:min(100%,520px)}.brand{font-weight:700;letter-spacing:.08em;font-size:13px;color:#b8bcae}h1{font-size:34px;line-height:1.15;letter-spacing:-.03em;margin:16px 0}p{color:#c4c8bc}button{width:100%;font:inherit;font-weight:600;min-height:50px;padding:12px 18px;border-radius:12px;border:1px solid #58604d;background:#e4f2ce;color:#18200f;cursor:pointer;margin:8px 0}button.secondary{background:transparent;color:#f4f4ed}button:disabled{opacity:.5;cursor:wait}a{color:#d2e6b8}input[type=checkbox]{width:22px;height:22px;vertical-align:middle;margin-right:8px}label{display:block}input[type=email],input[type=text]{width:100%;font:inherit;padding:12px;margin:8px 0 12px;border:1px solid #58604d;border-radius:8px;background:#111310;color:#f4f4ed}h2{font-size:22px;margin-top:0}[hidden]{display:none!important}button:focus-visible{outline:3px solid #bada8d;outline-offset:3px}.card{background:#1c2019;padding:20px;border-radius:16px;margin:24px 0}ul{padding-left:22px}li{margin:12px 0}small{display:block;color:#aeb5a5;overflow-wrap:anywhere}code{font-size:13px;overflow-wrap:anywhere}#error{color:#ffbaac;min-height:24px}details{margin:16px 0}pre{white-space:pre-wrap;overflow-wrap:anywhere;font-size:12px}`;
function page(title, content, script = '', status = 200) {
  const nonce = crypto.randomUUID().replace(/-/g, '');
  return new Response(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${escape(title)} · Thumble</title><style nonce="${nonce}">${css}</style></head><body><main><div class="brand">THUMBLE</div>${content}<p id="error" role="alert" aria-live="polite"></p></main>${script ? `<script nonce="${nonce}">${script}</script>` : ''}</body></html>`, { status, headers: {
    'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store', pragma: 'no-cache',
    'content-security-policy': `default-src 'none'; style-src 'nonce-${nonce}'; script-src 'nonce-${nonce}'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'`,
    'referrer-policy': 'no-referrer', 'x-content-type-options': 'nosniff', 'x-frame-options': 'DENY',
  } });
}
function errorPage(message, status = 400) { return page('Connection unavailable', `<h1>Connection unavailable</h1><p>${escape(message)}</p><p>Return to Thumble or your AI and start connecting again.</p>`, '', status); }
const clientScript = `
const buttons = [...document.querySelectorAll('button')];
const error = document.getElementById('error');
async function post(path, body, fallbackURL) {
  buttons.forEach(button => button.disabled = true); error.textContent = '';
  try {
    const response = await fetch(path, {method:'POST', credentials:'same-origin', headers:{'content-type':'application/json'}, body:JSON.stringify(body)});
    const data = await response.json();
    if (!response.ok || data.error) throw Error(data.error?.message || data.message || 'The connection could not be completed. Try again.');
    const target = data.url || data.redirect_uri || data.redirectURI || fallbackURL;
    if (!target) throw Error('The authorization service did not provide the next step. Start connecting again.');
    const next = new URL(target, location.origin);
    if (!['https:', 'http:', 'thumble:', 'thumble-receiver:'].includes(next.protocol)) throw Error('The authorization service returned an unsupported destination.');
    location.assign(next.href);
  } catch (failure) { error.textContent = failure.message; buttons.forEach(button => button.disabled = false); }
}
`;


async function sessionAccountId(issuer, userId) {
  return [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`${issuer}\n${userId}`)))].map(byte => byte.toString(16).padStart(2, '0')).join('');
}
function socialButtons(providers) {
  return providers.filter(provider => ['apple', 'google'].includes(provider)).map(provider => `<button data-provider="${provider}">Continue with ${provider === 'apple' ? 'Apple' : 'Google'}</button>`).join('');
}
function emailForm(providers) {
  if (!providers.includes('email')) return '';
  return `<section class="card" aria-label="Email sign-in"><h2>Sign in with email</h2><form id="email-form"><label for="email">Email address</label><input id="email" name="email" type="email" autocomplete="email" required maxlength="254"><button type="submit">Send sign-in code</button></form><form id="code-form" hidden><p id="code-status" role="status">Check your inbox for a six-digit code. It expires in 5 minutes. If it does not arrive, try again shortly.</p><label for="code">Sign-in code</label><input id="code" name="code" type="text" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}" minlength="6" maxlength="6" required><button type="submit">Verify and continue</button><button id="change-email" type="button" class="secondary">Use a different email</button></form></section>`;
}
function emailScript(callbackURL, query = '') {
  return `
const emailForm = document.getElementById('email-form');
if (emailForm) {
  const emailInput = document.getElementById('email'), codeForm = document.getElementById('code-form'), codeInput = document.getElementById('code');
  emailForm.addEventListener('submit', async event => {
    event.preventDefault(); if (!emailForm.reportValidity()) return;
    buttons.forEach(button => button.disabled = true); error.textContent = '';
    try {
      const response = await fetch('/api/auth/email-otp/send-verification-otp', {method:'POST',credentials:'same-origin',headers:{'content-type':'application/json'},body:JSON.stringify({email:emailInput.value.trim(),type:'sign-in'})});
      const data = await response.json();
      if (!response.ok || data.error || data.success !== true) throw Error(data.error?.message || data.message || 'The code could not be sent. Try again shortly.');
      emailInput.readOnly = true; emailForm.hidden = true; codeForm.hidden = false; codeInput.focus();
    } catch (failure) { error.textContent = failure.message; }
    finally { buttons.forEach(button => button.disabled = false); }
  });
  codeForm.addEventListener('submit', event => {
    event.preventDefault(); if (!codeForm.reportValidity()) return;
    return post('/api/auth/sign-in/email-otp', {email:emailInput.value.trim(),otp:codeInput.value${query ? `,oauth_query:${scriptValue(query)}` : ''}}, ${scriptValue(callbackURL)});
  });
  document.getElementById('change-email').addEventListener('click', () => { codeForm.hidden = true; codeInput.value = ''; emailInput.readOnly = false; emailForm.hidden = false; error.textContent = ''; emailInput.focus(); });
}
`;
}
async function accountPage(request, config, auth) {
  const url = new URL(request.url);
  const expectedIds = url.searchParams.getAll('accountId');
  if (expectedIds.length > 1 || (expectedIds.length && !/^[a-f0-9]{64}$/.test(expectedIds[0]))) return errorPage('The account management link is invalid. Open account management from Thumble again.');
  const expected = expectedIds[0] || null;
  const callback = new URL('/account', config.baseURL);
  if (expected) callback.searchParams.set('accountId', expected);
  const session = await auth.api.getSession({ headers: request.headers });
  const providers = socialButtons(config.providers) + emailForm(config.providers);
  const loginScript = `${clientScript}\nconst callbackURL = ${scriptValue(callback.href)};\nbuttons.filter(button => button.dataset.provider).forEach(button => button.addEventListener('click', () => post('/api/auth/sign-in/social', {provider:button.dataset.provider,callbackURL})));${emailScript(callback.href)}`;
  if (!session?.user) {
    if (!providers) return errorPage('Sign-in has not been configured for this service yet.', 503);
    return page('Manage account', `<h1>Manage your account.</h1><p>Sign in with the same account you used on your phone.</p>${providers}`, loginScript);
  }
  const accountId = await sessionAccountId(config.accountIssuer ?? config.issuer, session.user.id);
  const identity = `<p>Signed in as ${escape(session.user.email || session.user.name || 'your Thumble account')}.</p>`;
  if (expected && expected !== accountId) return page('Choose the connected account', `<h1>This is a different account.</h1>${identity}<p>Sign in with the identity connected to your phone to manage that account. No account has been deleted.</p>${providers}`, loginScript, 409);
  const context = await auth.$context;
  const freshAge = context.sessionConfig?.freshAge > 0 ? context.sessionConfig.freshAge : 300;
  const createdAt = new Date(session.session?.createdAt).getTime();
  if (!Number.isFinite(createdAt) || Date.now() - createdAt >= freshAge * 1000) return page('Confirm your identity', `<h1>Sign in again to continue.</h1>${identity}<p>Account deletion requires a recent sign-in. Use the same identity connected to your phone.</p>${providers || '<p>Social sign-in is currently unavailable. No account has been deleted.</p>'}`, providers ? loginScript : '', providers ? 200 : 503);
  const content = `<h1>Delete your Thumble account?</h1>${identity}<div class="card"><p>This permanently removes:</p><ul><li>Your cloud controllers and every saved revision</li><li>Your registered cloud phones and delivery history</li><li>Your sign-in sessions and AI connection permissions</li></ul><p>Thumble clears the cached cloud controller on this phone after it verifies deletion. Offline copies on other devices remain until those devices reconnect or sign out.</p><label><input id="confirm-delete" type="checkbox"> I understand that this permanently deletes my cloud account and controllers.</label></div><button id="delete-account" disabled>Delete my account permanently</button><p><a href="thumble://cloud-account/callback">Return to Thumble</a></p><section id="reauth" hidden><p>Sign in again to confirm your identity, then review deletion.</p>${providers}</section>`;
  const script = `${loginScript}\nconst confirm = document.getElementById('confirm-delete'); const remove = document.getElementById('delete-account');\nconfirm.addEventListener('change', () => remove.disabled = !confirm.checked);\nremove.addEventListener('click', async () => {\n  if (!confirm.checked) return;\n  buttons.forEach(button => button.disabled = true); error.textContent = '';\n  try {\n    const response = await fetch('/api/auth/delete-user', {method:'POST',credentials:'same-origin',headers:{'content-type':'application/json','x-thumble-account-id':${scriptValue(accountId)}},body:JSON.stringify({})});\n    const data = await response.json();\n    if (!response.ok || data.success !== true || data.message !== 'User deleted') throw Error(data.error?.message || data.message || 'The account could not be deleted. Try again.');\n    document.querySelector('main').innerHTML = '<div class="brand">THUMBLE</div><h1>Your account is deleted.</h1><p>Your cloud controllers, phone connections and sign-in sessions have been removed.</p><p><a href="thumble://cloud-account/callback">Return to Thumble</a> to clear the cached cloud controller on this phone.</p>';\n  } catch (failure) { error.textContent = failure.message; document.getElementById('reauth').hidden = false; buttons.forEach(button => button.disabled = false); remove.disabled = !confirm.checked; }\n});`;
  return page('Delete account', content, script);
}

/** Browser views only. Better Auth owns all OAuth validation, sessions and grants. */
export async function handleAuthPage(request, env, dependencies = {}) {
  const url = new URL(request.url);
  if (!['/sign-in', '/consent', '/account'].includes(url.pathname)) return null;
  if (request.method !== 'GET') return new Response('Method not allowed', { status: 405, headers: { allow: 'GET', 'cache-control': 'no-store' } });
  try {
    const config = (dependencies.identityConfig || identityConfig)(env);
    const auth = await (dependencies.createIdentity || createIdentity)(env);
    if (url.pathname === '/account') return await accountPage(request, config, auth);
    const query = url.search.slice(1);
    let params = null;
    if (query) {
      const { secret } = await auth.$context;
      if (!(await (dependencies.verifyOAuthQueryParams || verifyOAuthQueryParams)(query, secret))) return errorPage('This authorization request was changed or has expired.');
      params = new URLSearchParams(query);
    }
    const session = await auth.api.getSession({ headers: request.headers });
    if (url.pathname === '/sign-in') {
      if (session?.user && !params) return page('Signed in', `<h1>You’re signed in.</h1><p>Return to Thumble or your AI to finish connecting.</p>`);
      const providers = config.providers.filter(provider => ['apple', 'google'].includes(provider));
      if (!providers.length && !config.providers.includes('email')) return errorPage('Sign-in has not been configured for this service yet.', 503);
      const callbackURL = new URL(`/sign-in${query ? `?${query}` : ''}`, config.baseURL).href;
      const content = `<h1>Connect your Thumble account.</h1><p>Sign in to continue connecting your phone and AI.</p>${socialButtons(providers)}${emailForm(config.providers)}<p><small>Your AI receives only the permissions you approve on the next screen.</small></p>`;
      return page('Sign in', content, `${clientScript}\nconst oauthQuery = ${scriptValue(query)}; const callbackURL = ${scriptValue(callbackURL)};\nbuttons.filter(button => button.dataset.provider).forEach(button => button.addEventListener('click', () => post('/api/auth/sign-in/social', {provider:button.dataset.provider,callbackURL,...(oauthQuery ? {oauth_query:oauthQuery} : {})})));${emailScript(callbackURL, query)}`);
    }
    if (!params || !params.get('client_id')) return errorPage('Start authorization from your phone or AI to review its requested access.');
    if (!session?.user) return new Response(null, { status: 303, headers: { location: new URL(`/sign-in?${query}`, config.baseURL).href, 'cache-control': 'no-store' } });
    const client = await auth.api.getOAuthClientPublic({ headers: request.headers, query: { client_id: params.get('client_id') } });
    if (!client) return errorPage('This application is no longer available.');
    const scopes = [...new Set((params.get('scope') || '').split(/\s+/).filter(Boolean))];
    const resources = params.getAll('resource');
    let claims = null;
    if (params.get('claims')) { try { claims = JSON.parse(params.get('claims')); } catch { return errorPage('The authorization request contains invalid identity claims.'); } }
    const content = `<h1>Allow ${escape(client.client_name || client.name || params.get('client_id'))} to connect?</h1><p>Signed in as ${escape(session.user.email || session.user.name || 'your Thumble account')}.</p><div class="card"><small>Application ID</small><code>${escape(params.get('client_id'))}</code><ul>${scopes.map(scope => `<li>${escape(descriptions[scope] || scope)}<small>${escape(scope)}</small></li>`).join('')}</ul><small>Requested service${resources.length === 1 ? '' : 's'}</small>${resources.length ? resources.map(resource => `<p><code>${escape(resource)}</code></p>`).join('') : '<p>No resource-specific access token requested.</p>'}${claims ? `<details><summary>Requested identity claims</summary><pre>${escape(JSON.stringify(claims, null, 2))}</pre></details>` : ''}</div><p>Controller delivery confirms a phone preview. This connection does not control your Mac or change game bindings.</p><button data-accept="true">Allow access</button><button class="secondary" data-accept="false">Cancel</button>`;
    return page('Review access', content, `${clientScript}\nconst oauthQuery = ${scriptValue(query)};\nbuttons.forEach(button => button.addEventListener('click', () => post('/api/auth/oauth2/consent', {accept:button.dataset.accept === 'true',oauth_query:oauthQuery})));`);
  } catch { return errorPage('The sign-in service could not load this authorization request.', 503); }
}
