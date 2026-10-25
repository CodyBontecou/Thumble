import { museAuthorization } from './muse-client.js';
import { clineAuthorization } from './cline-client.js';
import { betterAuth } from 'better-auth';
import { jwt, emailOTP } from 'better-auth/plugins';
import { emailSignInEnabled, sendSignInCode } from './email-sign-in.js';
import { mcp } from '@better-auth/mcp';
import { generateAppleClientSecret } from './apple.js';
import { FRESH_SESSION_SECONDS, prepareAccountDeletion, completeAccountDeletion } from './deletion.js';
export { generateAppleClientSecret } from './apple.js';
import { CLOUD_SCOPES, CloudError, validServiceUrl } from '@tapping/cloud-contracts';
import { GLAMA_CLIENT_PREFIX, GLAMA_MONITOR_SCOPES, readGlamaRegistration, glamaAuthorization } from './glama-monitor.js';

export const IDENTITY_SCOPES = Object.freeze(['openid', 'offline_access', ...CLOUD_SCOPES]);
export const CHATGPT_SCOPES = Object.freeze(IDENTITY_SCOPES.filter(scope => !['devices:manage', 'pairing:manage'].includes(scope)));
export const MOBILE_SCOPES = Object.freeze(IDENTITY_SCOPES.filter(scope => !scope.startsWith('pairing:')));
export const RECEIVER_SCOPES = Object.freeze(['openid', 'pairing:manage']);
export const RECEIVER_REDIRECT_URI = 'thumble-receiver://cloud-auth/callback';
export const MOBILE_REDIRECT_URI = 'thumble://cloud-auth/callback';
const instances = new WeakMap();
const clientSetup = new WeakMap();
const legacyEnvironments = new WeakMap();

// Only the explicitly configured former origin gets its own auth instance.
// Cached clients retain issuer, callback, cookie and refresh endpoint semantics.
export function identityEnvironment(request, env) {
  if (!env.LEGACY_AUTH_URL || new URL(request.url).origin !== env.LEGACY_AUTH_URL) return env;
  let legacy = legacyEnvironments.get(env);
  if (!legacy) {
    identityConfig(env); // Validate the migration configuration before using it.
    legacy = { ...env, BETTER_AUTH_URL: env.LEGACY_AUTH_URL, AUTH_CANONICAL_URL: env.BETTER_AUTH_URL };
    legacyEnvironments.set(env, legacy);
  }
  return legacy;
}

export function identityConfig(env) {
  if (!validServiceUrl(env.BETTER_AUTH_URL) || new URL(env.BETTER_AUTH_URL).pathname !== '/') throw new CloudError('not_configured', 'The authentication service URL is not configured.', 503);
  const baseURL = new URL(env.BETTER_AUTH_URL).origin;
  const resource = env.MCP_RESOURCE_URL ?? `${baseURL}/mcp`;
  if (!validServiceUrl(resource) || new URL(resource).pathname !== '/mcp') throw new CloudError('not_configured', 'The MCP resource must be a canonical HTTPS /mcp URL.', 503);
  // Keep the original audience usable while installed phone sessions migrate.
  const origins = [...new Set([baseURL, env.LEGACY_AUTH_URL, env.AUTH_CANONICAL_URL].filter(Boolean))];
  if (origins.some(origin => !validServiceUrl(origin) || new URL(origin).origin !== origin)) throw new CloudError('not_configured', 'Authentication origins must be exact HTTPS origins.', 503);
  const accountIssuer = env.ACCOUNT_ID_ISSUER ?? `${baseURL}/api/auth`;
  if (!origins.some(origin => accountIssuer === `${origin}/api/auth`)) throw new CloudError('not_configured', 'The account identity namespace must belong to a configured authentication origin.', 503);
  const resources = [...new Set([resource, ...origins.map(origin => `${origin}/mcp`)])];
  const providers = [];
  if (env.GOOGLE_CLIENT_ID && env.GOOGLE_CLIENT_SECRET) providers.push('google');
  if (env.APPLE_CLIENT_ID && env.APPLE_TEAM_ID && env.APPLE_KEY_ID && env.APPLE_PRIVATE_KEY) providers.push('apple');
  if (emailSignInEnabled(env)) providers.push('email');
  return { baseURL, issuer: `${baseURL}/api/auth`, accountIssuer, issuers: origins.map(origin => `${origin}/api/auth`), resource, resources, mobileClientId: 'thumble-mobile', providers, scopes: [...IDENTITY_SCOPES] };
}


async function mapAppleProfile(env, profile) {
  const result = { image: null };
  if (profile.email || typeof profile.sub !== 'string') return result;
  // Apple can omit email on returning authorization. Recover only the same
  // already-linked provider subject; a new subject still needs provider email.
  const context = await (await createIdentity(env)).$context;
  const account = await context.adapter.findOne({ model: 'account', where: [{ field: 'providerId', value: 'apple' }, { field: 'accountId', value: profile.sub }] });
  const user = account ? await context.internalAdapter.findUserById(account.userId) : null;
  return user ? { ...result, email: user.email, emailVerified: user.emailVerified, name: user.name } : result;
}

// Exported for version-matched schema generation; no request can supply options.
export function identityOptions(env) {
  const config = identityConfig(env);
  if (typeof env.BETTER_AUTH_SECRET !== 'string' || env.BETTER_AUTH_SECRET.length < 32 || !env.DB) throw new CloudError('not_configured', 'Authentication storage and signing secret must be configured.', 503);
  const socialProviders = {};
  if (config.providers.includes('google')) socialProviders.google = { clientId: env.GOOGLE_CLIENT_ID, clientSecret: env.GOOGLE_CLIENT_SECRET, mapProfileToUser: () => ({ image: null }) };
  if (config.providers.includes('apple')) socialProviders.apple = async () => ({ clientId: env.APPLE_CLIENT_ID, clientSecret: await generateAppleClientSecret(env), mapProfileToUser: profile => mapAppleProfile(env, profile) });
  return {
    appName: 'Thumble', baseURL: config.baseURL, basePath: '/api/auth', secret: env.BETTER_AUTH_SECRET,
    database: env.DB,
    advanced: {
      ipAddress: { ipAddressHeaders: ['cf-connecting-ip'] },
      // Apple returns an OAuth form POST across sites. Only the short-lived
      // double-submit state cookies need SameSite=None; sessions stay Lax.
      ...(config.providers.includes('apple') ? { cookies: { state: { attributes: { sameSite: 'none', secure: true, path: '/api/auth/callback' } }, oauth_state: { attributes: { sameSite: 'none', secure: true, path: '/api/auth/callback' } } } } : {}),
    },
    trustedOrigins: [config.baseURL, ...(config.providers.includes('apple') ? ['https://appleid.apple.com'] : [])],
    socialProviders,
    logger: { level: 'warn', log: level => {
      const event = level === 'error' ? 'identity_error' : 'identity_warning';
      console.warn(JSON.stringify({ event }));
    } },
    emailAndPassword: { enabled: false },
    // Provider ID tokens are needed during identity verification only. Keeping
    // access/refresh tokens supports revocation without retaining avatar claims.
    databaseHooks: { account: {
      create: { before: async account => ({ data: { ...account, idToken: null } }) },
      update: { before: async account => ({ data: { ...account, idToken: null } }) },
    } },
    session: { freshAge: FRESH_SESSION_SECONDS },
    user: { deleteUser: { enabled: true, beforeDelete: async (user, request) => {
      const context = await (await createIdentity(env)).$context;
      await prepareAccountDeletion(env, { user, request, context, issuer: config.accountIssuer });
    }, afterDelete: user => completeAccountDeletion(env, user) } },
    account: { encryptOAuthTokens: true, accountLinking: { enabled: true, requireLocalEmailVerified: true, allowDifferentEmails: false } },
    rateLimit: { enabled: true, storage: 'database', window: 60, max: 100, customRules: { '/oauth2/register': { window: 60, max: 5 } } },
    disabledPaths: ['/token', '/email-otp/check-verification-otp', '/email-otp/verify-email', '/email-otp/request-password-reset', '/email-otp/forget-password', '/email-otp/reset-password', '/email-otp/request-email-change', '/email-otp/change-email'],
    plugins: [
      ...(config.providers.includes('email') ? [emailOTP({ otpLength: 6, expiresIn: 300, allowedAttempts: 3, storeOTP: 'hashed', resendStrategy: 'rotate', rateLimit: { window: 60, max: 3 }, sendVerificationOTP: data => sendSignInCode(env, data) })] : []),
      jwt({ disableSettingJwtHeader: true, jwks: { keyPairConfig: { alg: 'ES256' }, rotationInterval: 30 * 86400 }, jwt: { issuer: config.issuer, audience: config.resource, expirationTime: '15m' } }),
      mcp({
        loginPage: '/sign-in', consentPage: '/consent', resource: config.resource,
        resources: config.resources.map(identifier => ({ identifier, allowedScopes: [...IDENTITY_SCOPES], accessTokenTtl: 900 })),
        // These resources are operator-managed. Refresh configured policy fields
        // on existing rows too; insert-only seeding silently drops newly added scopes.
        resourceSeedMode: 'merge',
        scopes: [...IDENTITY_SCOPES], advertisedMetadata: { scopes_supported: [...CHATGPT_SCOPES] }, grantTypes: ['authorization_code', 'refresh_token'],
        allowDynamicClientRegistration: Boolean(env.GLAMA_MONITOR_EMAIL), allowUnauthenticatedClientRegistration: Boolean(env.GLAMA_MONITOR_EMAIL),
        generateClientId: () => `${GLAMA_CLIENT_PREFIX}${crypto.randomUUID()}`,
        clientRegistrationDefaultScopes: [...GLAMA_MONITOR_SCOPES], clientRegistrationAllowedScopes: [],
        clientRegistrationDefaultResources: [config.resource], clientRegistrationAllowedResources: [config.resource],
        clientRegistrationRequirePKCE: true,
        cachedTrustedClients: new Set(['thumble-mobile', 'thumble-chatgpt', 'thumble-receiver']),
        // Better Auth 1.7.12 infers public-token support from registration or
        // client discovery, overlooking pre-provisioned public clients. This
        // supported registry extension resolves only our fixed stored clients,
        // so discovery advertises `none` without opening any registration.
        extensions: [{ clientDiscovery: {
          id: 'thumble-managed-public-clients',
          matches: clientId => ['thumble-mobile', 'thumble-chatgpt', 'thumble-receiver'].includes(clientId),
          resolve: async (ctx, clientId, existing) => {
            const client = existing ?? await ctx.context.adapter.findOne({ model: 'oauthClient', where: [{ field: 'clientId', value: clientId }] });
            return client?.tokenEndpointAuthMethod === 'none' ? client : null;
          },
        } }],
        // These fixed clients are provisioned by the operator, never user CRUD.
        clientPrivileges: () => false, resourcePrivileges: () => false,
      }),
    ],
  };
}

export async function createIdentity(env) {
  let instance = instances.get(env);
  if (!instance) { instance = betterAuth(identityOptions(env)); instances.set(env, instance); }
  return instance;
}

function configuredChatgptClient(env) {
  if (!env.CHATGPT_CLIENT_SECRET && !env.CHATGPT_REDIRECT_URIS) return null;
  const confidential = Boolean(env.CHATGPT_CLIENT_SECRET);
  if (confidential && (typeof env.CHATGPT_CLIENT_SECRET !== 'string' || env.CHATGPT_CLIENT_SECRET.length < 32)) throw new CloudError('not_configured', 'The ChatGPT OAuth client secret must be at least 32 characters.', 503);
  let redirectUris;
  try { redirectUris = JSON.parse(env.CHATGPT_REDIRECT_URIS); } catch { throw new CloudError('not_configured', 'ChatGPT redirect URIs must be a JSON array.', 503); }
  if (!Array.isArray(redirectUris) || !redirectUris.length || redirectUris.some(uri => !validServiceUrl(uri) || !['chatgpt.com', 'chat.openai.com'].includes(new URL(uri).hostname))) throw new CloudError('not_configured', 'Configure exact HTTPS ChatGPT redirect URIs.', 503);
  return { clientId: 'thumble-chatgpt', name: 'ChatGPT', redirectUris, applicationType: 'web', tokenEndpointAuthMethod: confidential ? 'client_secret_post' : 'none', requirePKCE: true, ...(confidential ? { secret: env.CHATGPT_CLIENT_SECRET } : {}) };
}
async function hashClientSecret(secret) {
  const bytes = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(secret)));
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
async function provisionClients(env) {
  const chatgpt = configuredChatgptClient(env);
  const auth = await createIdentity(env), context = await auth.$context, config = identityConfig(env);
  const clients = [
    { clientId: 'thumble-mobile', name: 'Thumble phone', redirectUris: [MOBILE_REDIRECT_URI], applicationType: 'native', tokenEndpointAuthMethod: 'none', requirePKCE: true },
    { clientId: 'thumble-receiver', name: 'Thumble Mac pairing', redirectUris: [RECEIVER_REDIRECT_URI], applicationType: 'native', tokenEndpointAuthMethod: 'none', requirePKCE: true },
  ];
  if (chatgpt) clients.push(chatgpt);
  else await context.adapter.update({ model: 'oauthClient', where: [{ field: 'clientId', value: 'thumble-chatgpt' }], update: { disabled: true, updatedAt: new Date() } });
  // Operator-managed rows with fixed IDs. Adapter serialization follows the
  // installed Better Auth schema; no hidden bootstrap user/session is created.
  for (const client of clients) {
    const { secret, ...registration } = client;
    const scopes = client.clientId === 'thumble-chatgpt' ? CHATGPT_SCOPES : client.clientId === 'thumble-receiver' ? RECEIVER_SCOPES : MOBILE_SCOPES;
    const data = { ...registration, clientSecret: secret ? await hashClientSecret(secret) : null, scopes: [...scopes], clientCredentialsScopes: [], grantTypes: client.clientId === 'thumble-receiver' ? ['authorization_code'] : ['authorization_code', 'refresh_token'], responseTypes: ['code'], subjectType: 'public', skipConsent: false, disabled: false, updatedAt: new Date() };
    const existing = await context.adapter.findOne({ model: 'oauthClient', where: [{ field: 'clientId', value: client.clientId }] });
    if (!existing) {
      try { await context.adapter.create({ model: 'oauthClient', data: { ...data, createdAt: new Date() } }); }
      catch (error) { if (!await context.adapter.findOne({ model: 'oauthClient', where: [{ field: 'clientId', value: client.clientId }] })) throw error; }
    } else {
      await context.adapter.update({ model: 'oauthClient', where: [{ field: 'clientId', value: client.clientId }], update: data });
    }
    for (const identifier of config.resources) {
      const resource = await context.adapter.findOne({ model: 'oauthResource', where: [{ field: 'identifier', value: identifier }] });
      if (!resource) throw new CloudError('not_configured', 'The OAuth resource schema has not been initialized.', 503);
      const link = await context.adapter.findOne({ model: 'oauthClientResource', where: [{ field: 'clientId', value: client.clientId }, { field: 'resourceId', value: resource.identifier }] });
      if (!link) {
        try { await context.adapter.create({ model: 'oauthClientResource', data: { clientId: client.clientId, resourceId: resource.identifier } }); }
        catch (error) { if (!await context.adapter.findOne({ model: 'oauthClientResource', where: [{ field: 'clientId', value: client.clientId }, { field: 'resourceId', value: resource.identifier }] })) throw error; }
      }
    }
  }
}
export async function ensureIdentityClients(env) {
  let setup = clientSetup.get(env);
  if (!setup) { setup = provisionClients(env); clientSetup.set(env, setup); }
  try { await setup; } catch (error) { clientSetup.delete(env); throw error; }
}
export async function handleIdentity(request, env) {
  await ensureIdentityClients(env);
  if (new URL(request.url).pathname.replace(/\/+$/, '') === '/api/auth/oauth2/register') {
    if (!env.GLAMA_MONITOR_EMAIL) return Response.json({ error: 'registration_not_supported' }, { status: 403 });
    if (request.method !== 'POST') return Response.json({ error: 'invalid_request' }, { status: 405 });
    if (Number(request.headers.get('content-length')) > 8192) return Response.json({ error: 'invalid_client_metadata' }, { status: 413 });
    let metadata;
    try { metadata = await readGlamaRegistration(request); }
    catch (error) { return Response.json({ error: error.code || 'invalid_client_metadata', error_description: error.message }, { status: error.status || 400 }); }
    request = new Request(request, { body: JSON.stringify(metadata) });
  }
  request = museAuthorization(clineAuthorization(glamaAuthorization(request)), identityConfig(env).resource);
  return (await createIdentity(env)).handler(request);
}
