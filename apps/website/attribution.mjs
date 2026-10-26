// Shared allowlists keep page attribution bounded in the browser and at ingestion.
const pages = new Set([
  '/', '/docs', '/guides', '/waitlist', '/support', '/about', '/blog',
  '/developers', '/api-policy', '/privacy', '/terms',
  '/blog/connect-chatgpt-claude', '/blog/development-update-october-2026',
  '/guides/wow-controller-mac', '/guides/consoleport-mac-setup',
  '/guides/install-thumble-wow-addon', '/guides/wow-controller-not-detected-mac',
  '/guides/thumble-phone-mac-pairing', '/guides/iphone-controller-mac',
  '/compare/wow-phone-vs-gamepad', '/compare/wow-controller-vs-keyboard-mouse-mac', '/guides/consoleport-keybindings-mac', '/guides/wow-addons-not-showing-mac', '/guides/wow-classic-controller-mac', '/guides/consoleport-spell-labels-not-syncing',
  '/guides/consoleport-wrong-action-modifier', '/guides/wow-controller-camera-reversed-mac',
]);
const campaigns = {
  utm_source: new Set(['google', 'bing', 'youtube', 'discord', 'github', 'newsletter']),
  utm_medium: new Set(['organic', 'social', 'email', 'referral']),
  utm_campaign: new Set(['wow-mac-launch', 'consoleport-guides', 'addon-launch']),
};
const storageKey = 'thumble-attribution-v1';

export function normalizeTouch(value) {
  const input = value && typeof value === 'object' ? value : {};
  const touch = { landing: pages.has(input.landing) ? input.landing : 'unknown' };
  for (const [key, allowed] of Object.entries(campaigns)) {
    if (typeof input[key] === 'string' && allowed.has(input[key])) touch[key] = input[key];
  }
  return touch;
}

export function normalizeAttribution(value) {
  return { first: normalizeTouch(value?.first), latest: normalizeTouch(value?.latest) };
}

export function captureAttribution(url, storage) {
  const parsed = new URL(url);
  const landing = parsed.pathname.replace(/\.html$/, '').replace(/\/$/, '') || '/';
  const current = normalizeTouch({ landing, ...Object.fromEntries(
    Object.keys(campaigns).map(key => [key, parsed.searchParams.get(key)])
  ) });
  let previous;
  try { previous = JSON.parse(storage?.getItem(storageKey) || 'null'); } catch { /* Storage is optional. */ }
  // This is the first observed landing in this tab, not a persistent visitor ID.
  const first = normalizeTouch(previous?.first);
  const result = { first: first.landing !== 'unknown' ? first : current, latest: current };
  try { storage?.setItem(storageKey, JSON.stringify(result)); } catch { /* Signup works without storage. */ }
  return result;
}
