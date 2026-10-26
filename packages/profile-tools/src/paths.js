import { homedir } from 'node:os';
import { join, win32, posix } from 'node:path';

/** Matches the desktop receiver defaults; the existing Mac store stays in place. */
export function profileDirectory({ platform = process.platform, env = process.env, home = homedir() } = {}) {
  if (env.TAPPING_PROFILE_DIR) return env.TAPPING_PROFILE_DIR;
  if (platform === 'win32') return win32.join(env.LOCALAPPDATA || win32.join(home, 'AppData', 'Local'), 'Thumble', 'profiles');
  if (platform === 'linux') return posix.join(env.XDG_STATE_HOME || posix.join(home, '.local', 'state'), 'thumble', 'profiles');
  return join(home, 'Library/Application Support/Tapping/profiles');
}
