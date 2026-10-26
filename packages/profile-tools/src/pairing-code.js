import { open, lstat } from 'node:fs/promises';
import { constants } from 'node:fs';
import { join } from 'node:path';
import { checkWindowsPairingFile } from './pairing-permissions.js';

/** Read only the receiver's private ephemeral image; never return the raw invitation. */
export async function showPairingCode(store, now = Date.now()) {
  let file;
  let payload;
  try {
    const path = join(store.directory, 'pairing-code.json');
    if ((await lstat(path)).isSymbolicLink()) throw Error('unsafe');
    file = await open(path, constants.O_RDONLY | (process.platform === 'win32' ? 0 : (constants.O_NOFOLLOW || 0)));
    const stat = await file.stat();
    if (!stat.isFile() || stat.size > 512 * 1024) throw Error('unsafe');
    if (process.platform === 'win32') await checkWindowsPairingFile(path);
    else if ((stat.mode & 0o077) !== 0 || stat.uid !== process.getuid()) throw Error('unsafe');
    payload = JSON.parse(await file.readFile('utf8'));
  } catch {
    throw Error('No current pairing code. Start the updated Thumble Receiver on this computer. If a phone is already paired, use controller_status; disconnect it manually only if you want to pair another phone.');
  } finally { await file?.close(); }
  if (payload.version !== 1 || !Number.isSafeInteger(payload.updatedAt) || now < payload.updatedAt || now - payload.updatedAt >= 5000 ||
      !Number.isSafeInteger(payload.expiresAt) || payload.expiresAt <= now || payload.expiresAt > now + 120_000) {
    throw Error('Pairing code is stale or expired. Keep Thumble Receiver running and call show_pairing_code again for its current code.');
  }
  if (typeof payload.png !== 'string' || !/^[A-Za-z0-9+/]+={0,2}$/.test(payload.png) ||
      !Buffer.from(payload.png, 'base64').subarray(0, 8).equals(Buffer.from('89504e470d0a1a0a', 'hex'))) {
    throw Error('Receiver pairing image is invalid. Restart the updated Thumble Receiver.');
  }
  return {
    content: [
      { type: 'text', text: `Scan this QR code in Thumble → Connect computer on the same Wi-Fi. Expires at ${new Date(payload.expiresAt).toISOString()}; single use. Display the returned image inline. Call show_pairing_code again if it expires. This tool does not open the receiver window.` },
      { type: 'image', mimeType: 'image/png', data: payload.png },
    ],
  };
}
