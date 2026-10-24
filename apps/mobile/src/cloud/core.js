import { assertProfile } from '@tapping/controller';
import { validServiceUrl } from '@tapping/cloud-contracts';

/** @typedef {{id: string, name: string}} Device */
/** @typedef {{service: string, accountId: string, accessToken: string, refreshToken?: string | null, expiresAt?: number | null, device: Device, deviceToken: string, deviceExpiresAt?: string, auth?: any, mcpUrl?: string}} Session */
/** @typedef {{id: string, deviceId: string, profileId: string, profileRevision: number, state: string}} Delivery */
/** @typedef {{profile: ReturnType<typeof assertProfile>, revision: number, delivery?: Delivery | null, cached?: boolean}} Selection */
/** @typedef {{id: string, name: string, revision: number}} ProfileSummary */

/** Cloud deliveries remain previews until explicit adoption through the paired Mac. */
export class CloudController {
  /** @param {{fetch?: typeof globalThis.fetch, storage: {load: () => Promise<any>, save: (value: any) => Promise<void>}, refreshToken?: ((session: Session) => Promise<any>) | null, now?: () => number, allowLocalhost?: boolean}} options */
  constructor({ fetch: request = globalThis.fetch, storage, refreshToken = null, now = Date.now, allowLocalhost = false }) {
    this.allowLocalhost = allowLocalhost; this.request = request; this.storage = storage; this.refreshToken = refreshToken; this.now = now;
  }
  /** @type {{loaded: boolean, busy: boolean, session: Session | null, profiles: ProfileSummary[], selected: Selection | null, pending: Delivery | null, error: string, foreground: boolean, lanOffline: boolean, renderAttempt: number, macAdoption: any}} */
  state = { loaded: false, busy: false, session: null, profiles: [], selected: null, pending: null, error: '', foreground: true, lanOffline: true, renderAttempt: 0, macAdoption: null };
  listeners = new Set();
  epoch = 0;
  polling = false;
  writes = Promise.resolve();
  subscribe = listener => { this.listeners.add(listener); return () => this.listeners.delete(listener); };
  snapshot = () => this.state;
  update(patch) { this.state = { ...this.state, ...patch }; this.listeners.forEach(listener => listener()); }
  persist(epoch = this.epoch) {
    const value = this.state.session ? { session: this.state.session, cache: this.cache } : null;
    this.writes = this.writes.catch(() => {}).then(() => epoch === this.epoch ? this.storage.save(value) : undefined);
    return this.writes;
  }
  /** @type {{profile: ReturnType<typeof assertProfile>, revision: number} | null} */
  cache = null;
  async load() {
    const epoch = this.epoch;
    try {
      const saved = await this.storage.load();
      if (epoch !== this.epoch) return;
      if (saved?.session && validServiceUrl(saved.session.service, this.allowLocalhost)) {
        const session = saved.session;
        if (!session.accountId || !session.device?.id || !session.deviceToken) throw Error('Sign in again to connect this phone.');
        this.cache = saved.cache ? { ...saved.cache, profile: assertProfile(saved.cache.profile) } : null;
        this.update({ session, selected: this.cache ? { ...this.cache, cached: true, delivery: null } : null });
      }
    } catch { if (epoch !== this.epoch) return; await this.storage.save(null); this.update({ error: 'Saved cloud connection could not be restored. Sign in again.' }); }
    finally { if (epoch === this.epoch) this.update({ loaded: true }); }
  }
  /** @param {string} path @param {{method?: string, body?: any, device?: boolean, session?: Partial<Session> | null}} options */
  async api(path, { method = 'GET', body, device = false, session = this.state.session } = {}) {
    if (!session) throw Error('Sign in to connect this phone.');
    const response = await this.request(`${session.service}${path}`, {
      method, headers: { Authorization: `Bearer ${device ? session.deviceToken : session.accessToken}`, ...(body ? { 'Content-Type': 'application/json' } : {}) },
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
    const value = await response.json();
    if (!response.ok) {
      if (response.status === 401 && value.error?.code === 'account_deleted') await this.forgetDeletedAccount(session);
      const failure = Error(value.error?.message || 'Cloud request failed.'); Object.assign(failure, { code: value.error?.code, status: response.status }); throw failure;
    }
    return value;
  }
  /** @param {Partial<Session>} deleted */
  async forgetDeletedAccount(deleted) {
    const current = this.state.session;
    // A delayed response for another account/device must never erase the new
    // account's credentials. Only an authenticated account_deleted response
    // from our own service authorizes this automatic cleanup.
    if (!current || current.service !== deleted.service || current.accountId !== deleted.accountId || current.device.id !== deleted.device?.id) return;
    ++this.epoch; this.committedSelection = null; this.cache = null;
    this.update({ session: null, selected: null, pending: null, profiles: [], macAdoption: null, busy: false, error: 'Your cloud account was deleted. Saved cloud data has been removed from this phone.' });
    await this.persist();
  }
  async verifyAccountDeletion() {
    const session = this.state.session;
    if (!session) return false;
    try {
      // Check the still-held token first: deletion also revokes refresh tokens,
      // so refreshing first would obscure the explicit account_deleted code.
      await this.api('/v1/me', { session });
      return false;
    } catch (failure) {
      if (failure.code === 'account_deleted' && !this.state.session) return true;
      throw failure;
    }
  }
  /** @type {{epoch: number, promise: Promise<any>} | null} */
  tokenRefresh = null;
  async accountSession(epoch = this.epoch) {
    const session = this.state.session;
    if (!session || epoch !== this.epoch) return null;
    if (!session.expiresAt || session.expiresAt > this.now() + 30000) return session;
    if (!this.refreshToken || !session.refreshToken) throw Error('Your sign-in expired. Sign out and sign in again.');
    // Rotating refresh tokens may be spent once: every concurrent account read
    // in this session shares the same provider exchange.
    if (this.tokenRefresh?.epoch !== epoch) this.tokenRefresh = { epoch, promise: this.refreshToken(session) };
    const flight = this.tokenRefresh;
    try {
      const tokens = await flight.promise;
      if (epoch !== this.epoch) return null;
      this.update({ session: { ...session, ...tokens } });
      await this.persist(epoch);
      return epoch === this.epoch ? this.state.session : null;
    } finally { if (this.tokenRefresh === flight) this.tokenRefresh = null; }
  }
  async connect(service, tokens, info) {
    if (!validServiceUrl(service, this.allowLocalhost)) throw Error('Use an HTTPS cloud service URL.');
    await this.logout();
    const epoch = ++this.epoch;
    this.update({ busy: true, error: '' });
    let provisional = { service: service.replace(/\/$/, ''), ...tokens };
    try {
      const { accountId } = await this.api('/v1/me', { session: provisional });
      const registration = await this.api('/v1/devices', { method: 'POST', body: info, session: provisional });
      provisional = { ...provisional, accountId, device: registration.device, deviceToken: registration.deviceToken, deviceExpiresAt: registration.expiresAt };
      if (epoch !== this.epoch) { void this.api(`/v1/devices/${registration.device.id}`, { method: 'DELETE', session: provisional }).catch(() => {}); return; }
      this.update({ session: provisional, selected: null });
      await this.persist(epoch);
      await this.refreshProfiles();
    } catch (failure) { if (epoch === this.epoch) { this.update({ error: failure.message }); throw failure; } }
    finally { if (epoch === this.epoch) this.update({ busy: false }); }
  }
  async logout() {
    const previous = this.state.session;
    const refreshing = this.tokenRefresh?.epoch === this.epoch ? this.tokenRefresh : null;
    ++this.epoch; this.committedSelection = null; this.cache = null;
    this.update({ session: null, selected: null, pending: null, profiles: [], macAdoption: null, error: '', busy: false });
    // Queue erasure after any in-flight write, so a late save cannot resurrect credentials.
    await this.persist();
    if (previous) void (async () => {
      let session = previous;
      if (refreshing) session = { ...session, ...await refreshing.promise };
      else if (session.expiresAt && session.expiresAt <= this.now() + 30000 && session.refreshToken && this.refreshToken) session = { ...session, ...await this.refreshToken(session) };
      await this.api(`/v1/devices/${session.device.id}`, { method: 'DELETE', session });
    })().catch(() => {});
  }
  setEnvironment({ foreground = this.state.foreground, lanOffline = this.state.lanOffline }) {
    if (foreground !== this.state.foreground || lanOffline !== this.state.lanOffline) this.update({ foreground, lanOffline });
  }
  async refreshProfiles() {
    const epoch = this.epoch;
    try {
      const session = await this.accountSession(epoch);
      if (!session || epoch !== this.epoch) return;
      const result = await this.api('/v1/profiles', { session });
      if (epoch === this.epoch) this.update({ profiles: result.profiles, error: '' });
    } catch (failure) { if (epoch === this.epoch) this.update({ error: failure.message }); }
  }
  async preview(profileId, revision) {
    const epoch = this.epoch;
    this.update({ busy: true, error: '' });
    try {
      const session = await this.accountSession(epoch);
      if (!session || epoch !== this.epoch) return;
      const result = await this.api(`/v1/profiles/${encodeURIComponent(profileId)}/revisions/${revision}`, { session });
      const profile = assertProfile(result.profile);
      if (profile.id !== profileId || result.revision !== revision) throw Error('The cloud returned a different profile revision.');
      if (epoch !== this.epoch) return;
      if (this.state.pending) throw Error('Use the incoming controller before choosing another profile.');
      this.update({ selected: { profile, revision, delivery: null, cached: false } });
    } catch (failure) { if (epoch === this.epoch) this.update({ error: failure.message }); }
    finally { if (epoch === this.epoch) this.update({ busy: false }); }
  }
  async poll() {
    if (this.polling || !this.state.session || !this.state.foreground) return;
    this.polling = true;
    const epoch = this.epoch, session = this.state.session;
    try {
      const { deliveries } = await this.api(`/v1/devices/${session.device.id}/deliveries`, { device: true, session });
      if (epoch !== this.epoch || !this.state.foreground) return;
      const item = deliveries[0];
      if (!item) {
        // An empty queue can also mean the server committed our render receipt
        // but its response was lost. Reconcile that exact committed selection
        // with an idempotent receipt; a superseded receipt returns a conflict.
        if (this.state.selected && this.committedSelection === this.state.selected) {
          await this.rendered(this.state.selected, this.state.macAdoption);
          return;
        }
        if (this.state.pending) this.update({ pending: null, selected: this.cache ? { ...this.cache, cached: true, delivery: null } : null });
        return;
      }
      const { delivery } = item;
      const profile = assertProfile(item.profile);
      if (delivery.deviceId !== session.device.id || delivery.profileId !== profile.id || !Number.isSafeInteger(delivery.profileRevision) || delivery.profileRevision < 1) throw Error('The delivery does not match this phone and profile.');
      if (!['queued', 'received'].includes(delivery.state)) return;
      if (delivery.id === this.state.pending?.id) { this.update({ renderAttempt: this.state.renderAttempt + 1 }); return; }
      const { delivery: received } = await this.api(`/v1/devices/${session.device.id}/deliveries/${delivery.id}/ack`, { method: 'POST', device: true, session, body: { profileId: profile.id, profileRevision: delivery.profileRevision, state: 'received' } });
      if (epoch !== this.epoch || !this.state.foreground) return;
      this.update({ pending: received, selected: { profile, revision: delivery.profileRevision, delivery: received, cached: false }, error: '' });
    } catch (failure) { if (epoch === this.epoch) this.update({ error: failure.message }); }
    finally { this.polling = false; }
  }
  /** @type {Selection | null} */
  committedSelection = null;
  /** @type {Selection | null} */
  rendering = null;
  /** @param {Selection} selected @param {any} [macAdoption] */
  async rendered(selected, macAdoption = null) {
    const adopted = macAdoption && macAdoption === this.state.macAdoption && macAdoption.selection === selected;
    if (selected !== this.state.selected || !this.state.foreground || (!this.state.lanOffline && !adopted) || !this.state.session || selected.cached || this.rendering === selected) return;
    this.rendering = selected;
    this.committedSelection = selected;
    const epoch = this.epoch, session = this.state.session;
    try {
      if (selected.delivery) await this.api(`/v1/devices/${session.device.id}/deliveries/${selected.delivery.id}/ack`, { method: 'POST', device: true, session, body: { profileId: selected.profile.id, profileRevision: selected.revision, state: 'rendered' } });
      if (epoch !== this.epoch || selected !== this.state.selected) return;
      this.cache = { profile: selected.profile, revision: selected.revision };
      this.update({ selected: { ...selected, cached: true }, pending: null, error: '' });
      await this.persist(epoch);
    } catch (failure) {
      if (epoch === this.epoch && selected === this.state.selected) {
        if (failure.status === 409) this.update({ pending: null, selected: this.cache ? { ...this.cache, cached: true, delivery: null } : null });
        this.update({ error: failure.message });
      }
    } finally { if (this.rendering === selected) this.rendering = null; }
  }
}
