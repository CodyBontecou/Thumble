import { mkdir, readFile, writeFile, rename, rm, open } from 'node:fs/promises';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { assertProfile, builtInProfiles } from '../../controller/src/index.js';
import { profileDirectory } from './paths.js';

export const defaultDirectory = profileDirectory;
const initial = () => ({ version: 1, profiles: [], active: null });
function withBuiltIns(data) {
  for (const profile of builtInProfiles) if (!data.profiles.some(entry => entry.profile.id === profile.id)) {
    if (data.profiles.length >= 256) break;
    data.profiles.push({ revision: 1, profile: assertProfile(profile) });
  }
  return data;
}
const revision = value => Number.isSafeInteger(value) && value >= 0;

/** One atomic document is the transaction boundary for profiles and activation. */
export class ProfileStore {
  constructor(directory = defaultDirectory()) { this.directory = directory; }
  async read() {
    let data;
    try { data = JSON.parse(await readFile(join(this.directory, 'store.json'), 'utf8')); }
    catch (error) { if (error.code === 'ENOENT') return withBuiltIns(initial()); throw error; }
    if (data.version !== 1 || !Array.isArray(data.profiles) || data.profiles.length > 256) throw Error('Invalid profile store');
    const ids = new Set();
    for (const entry of data.profiles) {
      assertProfile(entry.profile);
      if (!revision(entry.revision) || entry.revision < 1 || ids.has(entry.profile.id)) throw Error('Invalid profile revision');
      ids.add(entry.profile.id);
    }
    if (data.active) {
      assertProfile(data.active.profile);
      if (!revision(data.active.revision) || data.active.revision < 1 || !revision(data.active.profileRevision)) throw Error('Invalid active revision');
    }
    return withBuiltIns(data);
  }
  async transaction(update) {
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    const lock = join(this.directory, 'write.lock');
    // Never silently remove another writer's lock, including after a crash.
    const deadline = Date.now() + 3000;
    while (true) {
      try { await mkdir(lock, { mode: 0o700 }); break; }
      catch (error) {
        if (error.code !== 'EEXIST') throw error;
        if (Date.now() >= deadline) throw Error(`Profile store busy. If no writer is running, remove ${lock}`);
        await new Promise(resolve => setTimeout(resolve, 25));
      }
    }
    const temporary = join(this.directory, `store-${randomUUID()}.tmp`);
    try {
      const data = await this.read();
      const result = update(data);
      const json = JSON.stringify(data);
      if (Buffer.byteLength(json) > 8 * 1024 * 1024) throw Error('Profile store exceeds 8 MiB');
      await writeFile(temporary, json, { mode: 0o600, flag: 'wx' });
      const file = await open(temporary, 'r+');
      try { await file.sync(); } finally { await file.close(); }
      await rename(temporary, join(this.directory, 'store.json'));
      return result;
    } finally { await rm(temporary, { force: true }); await rm(lock, { recursive: true }); }
  }
  async list() {
    const data = await this.read();
    return { profiles: data.profiles.map(({ revision, profile }) => ({ id: profile.id, name: profile.name, revision })), active: data.active };
  }
  async get(id) {
    const entry = (await this.read()).profiles.find(entry => entry.profile.id === id);
    if (!entry) throw Error(`Unknown profile: ${id}`);
    return entry;
  }
  async save(profile, expectedRevision) {
    const checked = assertProfile(profile);
    if (Buffer.byteLength(JSON.stringify(checked)) > 60000) throw Error('Profile exceeds 60000 bytes');
    if (!revision(expectedRevision)) throw Error('expectedRevision must be a nonnegative safe integer (0 creates a profile)');
    return this.transaction(data => {
      const index = data.profiles.findIndex(entry => entry.profile.id === checked.id);
      const previous = index < 0 ? 0 : data.profiles[index].revision;
      if (previous !== expectedRevision) throw Error(`Revision conflict: expected ${expectedRevision}, current ${previous}. Read again before editing.`);
      if (previous === Number.MAX_SAFE_INTEGER) throw Error('Revision exhausted');
      const entry = { revision: previous + 1, profile: checked };
      if (index < 0) { if (data.profiles.length >= 256) throw Error('Profile limit reached'); data.profiles.push(entry); }
      else data.profiles[index] = entry;
      return entry;
    });
  }
  async activate(id, profileRevision, expectedActivationRevision) {
    if (!revision(profileRevision) || !revision(expectedActivationRevision)) throw Error('Invalid revision');
    return this.transaction(data => {
      const entry = data.profiles.find(entry => entry.profile.id === id);
      if (!entry || entry.revision !== profileRevision) throw Error('Profile revision conflict. Read again before activating.');
      const previous = data.active?.revision ?? 0;
      if (previous !== expectedActivationRevision) throw Error(`Activation conflict: current ${previous}`);
      if (previous === Number.MAX_SAFE_INTEGER) throw Error('Revision exhausted');
      data.active = { revision: previous + 1, profileRevision, profile: entry.profile };
      return { ...data.active, delivery: 'queued', note: 'Use controller_status to confirm the paired phone acknowledged this activation.' };
    });
  }
  async status() {
    const active = (await this.read()).active;
    let receiver = null;
    try { receiver = JSON.parse(await readFile(join(this.directory, 'receiver-status.json'), 'utf8')); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    const fresh = receiver && Number.isFinite(receiver.updatedAt) && Date.now() - receiver.updatedAt >= 0 && Date.now() - receiver.updatedAt < 5000;
    const delivered = !!(fresh && receiver.connected === true && receiver.ready === true && active && receiver.revision === active.revision);
    return { active, receiver: fresh ? receiver : null, delivery: delivered ? 'acknowledged' : 'queued', note: fresh ? undefined : 'Receiver is stopped or has not reported recently.' };
  }
}
