/** The QR is a short-lived capability. Never log or persist its token. */
export function parseInvitation(value, now = Date.now()) {
  if (typeof value !== 'string' || value.length > 2048) throw new Error('Pairing code is too large.');
  const link = new URL(value.trim());
  if (link.protocol !== 'tapping:' || link.hostname !== 'pair' || link.pathname !== '') throw new Error('Scan a Tapping pairing code.');
  const encoded = link.searchParams.get('data');
  if (!encoded || !/^[A-Za-z0-9_-]+$/.test(encoded)) throw new Error('Invalid pairing code.');
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  let bits = 0, count = 0, json = '';
  for (const character of encoded) {
    bits = (bits << 6) | alphabet.indexOf(character); count += 6;
    if (count >= 8) { count -= 8; json += String.fromCharCode((bits >> count) & 255); }
  }
  const data = JSON.parse(json);
  if (data.v !== 1 || typeof data.url !== 'string' || !/^[a-f0-9]{64}$/.test(data.pin) || !/^[a-f0-9]{64}$/.test(data.token)) throw new Error('Unsupported pairing code.');
  const url = new URL(data.url);
  const octets = url.hostname.split('.').map(Number);
  const privateIP = octets.length === 4 && octets.every(part => Number.isInteger(part) && part >= 0 && part <= 255) &&
    (octets[0] === 10 || (octets[0] === 192 && octets[1] === 168) || (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31));
  if (url.protocol !== 'wss:' || !privateIP || !url.port || url.username || url.password || url.pathname !== '/controller' || url.search || url.hash) throw new Error('Pairing requires a Mac on local Wi-Fi.');
  if (!Number.isSafeInteger(data.expires) || data.expires * 1000 <= now || data.expires * 1000 > now + 180_000) throw new Error('Pairing code expired. Scan the current code on your Mac.');
  return Object.freeze({ url: url.href, pin: data.pin, token: data.token, expires: data.expires });
}
