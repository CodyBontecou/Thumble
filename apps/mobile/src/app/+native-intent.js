/** Scrawl pairing links (thumble://scrawl?…) are handled natively in Debug builds; a link that
 * cold-starts the app would otherwise open Expo Router's not-found screen.
 * @param {{path:string,initial:boolean}} event */
export function redirectSystemPath({ path }) {
  try {
    const url = new URL(path, 'thumble://app');
    if (url.protocol === 'thumble:' && url.hostname === 'scrawl') return '/';
  } catch {
    // Other links keep their existing routing.
  }
  return path;
}
