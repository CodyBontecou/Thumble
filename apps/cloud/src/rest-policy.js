import { sha256 } from './auth.js';

export const REST_LIMIT = 600;
export const REST_WINDOW = 60;

// The binding returns a decision, not a remaining counter. Advertise the actual
// policy on every response, and a conservative retry delay only after rejection.
export async function withRestPolicy(request, env, handle) {
  if (!env.REST_RATE_LIMITER) return handle(); // Local fixtures can omit the binding.
  const authorization = request.headers.get('authorization');
  const key = authorization?.startsWith('Bearer ')
    ? `credential:${await sha256(authorization)}`
    : `public:${request.headers.get('cf-connecting-ip') || 'local'}`;
  const { success } = await env.REST_RATE_LIMITER.limit({ key });
  const response = success ? await handle() : Response.json({ error: {
    code: 'rate_limit_exceeded', message: 'Too many REST requests. Wait 60 seconds before retrying.',
  } }, { status: 429 });
  const result = new Response(response.body, response);
  result.headers.set('Cache-Control', 'no-store');
  result.headers.set('RateLimit-Policy', `"thumble-rest";q=${REST_LIMIT};w=${REST_WINDOW}`);
  result.headers.set('X-RateLimit-Limit', String(REST_LIMIT));
  result.headers.set('Link', '<https://thumble.io/developers#rate-limits>; rel="service-doc"');
  if (!success) {
    result.headers.set('RateLimit', `"thumble-rest";r=0;t=${REST_WINDOW}`);
    result.headers.set('Retry-After', String(REST_WINDOW));
  }
  return result;
}
