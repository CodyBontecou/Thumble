import { Buffer } from 'node:buffer';

// Apple's CommonJS SDK requires a default export and node-fetch's buffer() response method.
// Wrangler's automatic shim exports a bare function to require(), losing that default.
const NativeHeaders = Headers;
export { NativeHeaders as Headers };
export const Request = globalThis.Request;
export const Response = globalThis.Response;
const NativeAbortController = AbortController;
export { NativeAbortController as AbortController };
export const FetchError = Error;
export const AbortError = Error;
/** @param {number} status */
export const isRedirect = (status) => [301, 302, 303, 307, 308].includes(status);

/** Apple rejects OCSP POSTs from the Workers fetch transport. RFC 6960 permits
 * the same DER request as a URL-encoded base64 GET for small requests.
 * @param {RequestInfo|URL} input @param {RequestInit} init */
function appleOcspGet(input, init) {
  if (
    (typeof input !== 'string' && !(input instanceof URL)) ||
    init.method?.toUpperCase() !== 'POST' ||
    !(init.body instanceof Uint8Array)
  )
    return null;
  const url = new URL(input);
  const headers = new Headers(init.headers);
  if (
    url.origin !== 'http://ocsp.apple.com' ||
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    headers.get('Content-Type') !== 'application/ocsp-request'
  )
    return null;
  url.pathname = `${url.pathname.replace(/\/$/, '')}/${encodeURIComponent(Buffer.from(init.body).toString('base64'))}`;
  if (url.href.length > 255) return null;
  headers.delete('Content-Type');
  headers.delete('Content-Length');
  return { url, headers };
}

/** @param {RequestInfo|URL} input @param {RequestInit & {timeout?:number}} [options] */
export default async function fetch(input, options = {}) {
  const { timeout, ...init } = options;
  const signal = timeout ? AbortSignal.timeout(timeout) : undefined;
  const ocsp = appleOcspGet(input, init);
  const response = await globalThis.fetch(ocsp?.url ?? input, {
    ...init,
    ...(ocsp ? { method: 'GET', headers: ocsp.headers, body: null } : {}),
    ...(signal ? { signal: init.signal ? AbortSignal.any([init.signal, signal]) : signal } : {}),
  });
  return Object.assign(response, {
    buffer: async () => Buffer.from(await response.arrayBuffer()),
  });
}
