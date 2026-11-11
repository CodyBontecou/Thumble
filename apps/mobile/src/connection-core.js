import { LatencyRecorder } from './latency-recorder.js';
import { neutralState, parseInvitation, parseReceiverEndpoint, assertProfile, defaultProfile } from '@tapping/controller';

const canonical = value => JSON.stringify(value, (_, item) => item && typeof item === 'object' && !Array.isArray(item) ? Object.fromEntries(Object.keys(item).sort().map(key => [key, item[key]])) : item);

export class Connection {
  listeners = new Set();
  accessListeners = new Set();
  /** @type {any} */
  access = null;
  demoUsed = 0;
  phoneId = "";
  subscribeAccess = listener => { this.accessListeners.add(listener); return () => this.accessListeners.delete(listener); };
  accessSnapshot = () => this.access;
  setAccess(access) { this.access = access; for (const listener of this.accessListeners) listener(); }
  pausePlay() {
    if (this.view.phase !== 'connected') return;
    this.setAccess(this.access && { ...this.access, enabled: false, running: false });
    this.state = neutralState(); this.outbox = []; this.pending.clear();
    this.native.send(JSON.stringify({ type: 'access-pause' }));
    for (const reset of this.resetListeners) reset();
  }
  resumePlay() {
    if (this.view.phase !== 'connected' || !this.access || (!this.access.pro && this.access.remaining <= 0)) return;
    this.native.send(JSON.stringify({ type: 'access-resume' }));
  }
  sendGrant(grant) { if (this.view.phase === 'connected') this.native.send(JSON.stringify({ type: 'access-grant', grant })); }
  get canPlay() { return !!this.access?.enabled && (this.access.pro || this.access.remaining > 0); }

  resetListeners = new Set();
  profileListeners = new Set();
  layout = { revision: 0, profile: assertProfile(defaultProfile) };
  layoutPending = false;
  view = { phase: 'offline', detail: 'Practice · Computer not connected', rtt: null, chat: false };
  /** @type {{id: string, resolve: (value?: any) => void, reject: (error: Error) => void, timer: ReturnType<typeof setTimeout>} | null} */
  chatRequest = null;
  profilesSupported = false;
  cloudAdoptionSupported = false;
  phoneProfileSaveSupported = false;
  phoneBindingsSupported = false;
  bindingRequest = /** @type {any} */ (null);
  profileSequence = 0;
  /** @type {any} */
  profileRequest = null;
  chatSequence = 0;
  /** @type {{url: string, pin: string, token?: string, expires?: number, reconnectToken?: string} | null} */
  invitation = null;
  /** @type {string | null} */
  lease = null;
  sequence = 0;
  inputTransport = 'wss';
  udpOffered = false;
  state = neutralState();
  /** @type {ReturnType<typeof setInterval> | null} */
  timer = null;
  pending = new Map();
  outbox = [];
  recovering = false;
  /** @type {ReturnType<typeof setTimeout> | null} */
  retryTimer = null;
  /** @type {LatencyRecorder | null} */
  diagnostics = null;
  lastAck = 0;
  lastMetric = 0;
  /** @type {string | null} */
  session = null;
  attempt = 0;
  /** @type {number | null} */
  inputTime = null;
  /** @type {any} */
  remembered = null;
  /** @type {any} */
  pairingStorage = null;
  storageWrite = Promise.resolve();
  native;
  beforeConnect;
  timers;
  now;
  constructor(native, { beforeConnect = async () => {}, timers = globalThis, now = () => performance.now() } = {}) {
    this.native = native; this.beforeConnect = beforeConnect; this.timers = timers; this.now = now;
    native.addListener('status', ({ value, id }) => {
      if (!this.session || id !== this.session) return;
      if (value === 'open' && this.invitation) this.native.send(JSON.stringify({ type: 'hello', v: 3, phoneId: this.phoneId, demoUsed: this.demoUsed, ...(this.invitation.reconnectToken ? { reconnectToken: this.invitation.reconnectToken } : { token: this.invitation.token }), datagram: typeof this.native.configureDatagram === 'function' ? 1 : 0 }));
      else if (value !== 'open' && this.view.phase !== 'offline') this.disconnect(value, { keepPairing: true });
    });
    native.addListener('message', ({ value, id, receivedAt, transport }) => {
      if (!this.session || id !== this.session) return;
      try {
        const message = JSON.parse(value);
        if (message.type === 'forgotten') {
          // The receiver no longer trusts this phone's reconnect credential; stop retrying.
          if (transport === 'udp' || this.view.phase !== 'connecting' || !this.invitation?.reconnectToken) throw Error('Unexpected forgotten');
          this.disconnect('Your computer forgot this phone. Scan its QR code to pair again.');
          return;
        }
        if (message.type === 'access') {
          if (transport === 'udp' || this.view.phase !== 'connected' || message.v !== 1 || typeof message.pro !== 'boolean' || typeof message.enabled !== 'boolean' || typeof message.running !== 'boolean' || !Number.isFinite(message.remaining) || message.remaining < 0 || message.remaining > 1800 || !Number.isFinite(message.debitedUsed) || message.debitedUsed < 0 || message.debitedUsed > 1800 || typeof message.receiverId !== 'string' || typeof message.nonce !== 'string' || !/^[a-f0-9-]{36}$/i.test(message.receiverId) || !/^[a-f0-9-]{36}$/i.test(message.nonce)) throw Error('Invalid access status');
          const blocked = this.canPlay && (!message.enabled || (!message.pro && message.remaining <= 0));
          this.setAccess(message);
          if (blocked) {
            this.outbox = []; this.state = neutralState();
            for (const reset of this.resetListeners) reset();
          }
          return;
        }
        if (message.type === 'bindings-result') {
          if (transport === 'udp' || !this.bindingRequest || this.bindingRequest.id !== message.id) return;
          this.finishBindingRequest(message.error ? Error(String(message.error)) : null, message.data);
          return;
        }
        if (message.type === 'profiles-result') {
          const request = this.profileRequest;
          if (transport === 'udp' || !request || request.id !== message.id) return;
          if (message.error) { this.finishProfileRequest(Error(String(message.error))); return; }
          const catalog = message.catalog;
          if (!catalog || !Number.isSafeInteger(catalog.activationRevision) || catalog.activationRevision < 0 || !Array.isArray(catalog.profiles) || catalog.profiles.length > 256 || new Set(catalog.profiles.map(p => p?.id)).size !== catalog.profiles.length || catalog.profiles.some(p => !p || typeof p.id !== 'string' || !/^[a-z0-9][a-z0-9-]{0,63}$/.test(p.id) || typeof p.name !== 'string' || !p.name.length || p.name.length > 80 || !Number.isSafeInteger(p.revision) || p.revision < 1)) {
            this.finishProfileRequest(Error('The receiver returned an invalid profile list.')); return;
          }
          request.result = catalog;
          if (request.operation === 'profile-adopt') {
            const adoption = catalog.adoption;
            if (!adoption || !/^cloud-[a-f0-9]{40}$/.test(adoption.profileId) || adoption.profileRevision !== 1 || canonical(adoption.source) !== canonical(request.source)) {
              this.finishProfileRequest(Error('The receiver did not confirm the requested cloud revision.')); return;
            }
            request.profileId = adoption.profileId;
          }
          if (request.operation === 'profiles-list') this.finishProfileRequest();
          else this.completeProfileSelection();
          return;
        }
        if (message.type === 'chat-result') {
          if (transport === 'udp' || !this.chatRequest || message.id !== this.chatRequest.id) return;
          const request = this.chatRequest; this.chatRequest = null;
          this.timers.clearTimeout(request.timer);
          if (message.error) request.reject(Error(String(message.error)));
          else request.resolve();
          return;
        }
        if (message.type === 'udp-offer') {
          if (this.view.phase !== 'connected' || this.udpOffered || transport === 'udp') return;
          if (!Number.isInteger(message.port) || message.port < 1 || message.port > 65535 || typeof message.key !== 'string' || !/^[A-Za-z0-9+/]{43}=$/.test(message.key)) throw Error('Invalid datagram offer');
          this.udpOffered = true;
          if (typeof this.native.configureDatagram === 'function') this.native.configureDatagram(message.port, message.key);
          return;
        }
        if (message.type === 'udp-ready') {
          if (!this.udpOffered || transport !== 'udp' || this.view.phase !== 'connected' || this.inputTransport === 'udp') return;
          this.inputTransport = 'udp';
          this.state = neutralState();
          for (const reset of this.resetListeners) reset();
          this.submit(neutralState(), 'neutral');
          return;
        }
        if (message.type === 'layout') { this.receiveLayout(message); return; }
        if (message.type === 'ready' && message.access !== 1) { this.disconnect('Update your receiver to use the demo and Pro features.'); return; }
        if (!['ready', 'ack', 'paused'].includes(message.type) || typeof message.lease !== 'string') throw new Error('Invalid receiver response');
        if (this.view.phase !== 'connecting' && this.view.phase !== 'connected') return;
        if (!message.lease || message.lease.length > 128 || !Number.isSafeInteger(message.seq)) throw new Error('Invalid receiver response');
        if (message.type === 'ready') {
          if (this.view.phase !== 'connecting' || message.seq !== -1 || message.access !== 1) throw new Error('Unexpected handshake');
        } else {
          if (this.view.phase !== 'connected' || message.seq < -1 || message.seq > this.sequence) throw new Error('Invalid input acknowledgement');
          if (message.type === 'ack' && !this.pending.has(message.seq)) return;
        }
        this.lastAck = this.now();
        if (message.type === 'paused') {
          if (this.diagnostics) this.diagnostics.counts.pauses++;
          this.pending.clear();
          this.outbox = [];
          this.recovering = true;
          this.update({ ...this.view, detail: 'Wi-Fi paused · controls released' });
          this.state = neutralState();
          this.lease = message.lease;
          for (const reset of this.resetListeners) reset();
          this.submit(neutralState(), 'neutral');
          return;
        }
        this.lease = message.lease;
        if (message.type === 'ready') {
          if (this.timer) this.timers.clearTimeout(this.timer);
          if (this.invitation && /^[a-f0-9]{64}$/.test(message.reconnectToken)) {
            this.remembered = { url: this.invitation.url, pin: this.invitation.pin, reconnectToken: message.reconnectToken };
            this.savePairing(this.remembered);
          }
          this.invitation = null;
          this.profilesSupported = message.profiles === 1;
          this.cloudAdoptionSupported = message.cloudAdoption === 1;
          this.phoneProfileSaveSupported = message.phoneProfileSave === 1;
          this.phoneBindingsSupported = message.phoneBindings === 1;
          this.diagnostics = message.diagnostics === true && typeof this.native.sendTimed === 'function' ? new LatencyRecorder(text => this.native.send(text)) : null;
          this.update({ phase: 'connected', detail: 'Connected · Xbox gamepad', rtt: null, chat: message.chat === 1 });
          this.submit(neutralState(), 'neutral');
          if (this.view.phase !== 'connected') return;
          this.timer = this.timers.setInterval(() => {
            if (this.now() - this.lastAck > 1500) this.disconnect('Connection stalled · controls released', { keepPairing: true });
            else this.submit(this.state, 'heartbeat');
          }, 33);
        } else {
          const sent = this.pending.get(message.seq);
          if (sent && this.diagnostics) this.diagnostics.record(sent, receivedAt, this.lastAck, message);
          if (sent != null && this.lastAck - this.lastMetric > 1000) {
            this.lastMetric = this.lastAck;
            this.update({ ...this.view, rtt: Math.round(this.lastAck - sent.js) });
          }
          for (const sequence of this.pending.keys()) if (sequence <= message.seq) { if (sequence < message.seq && this.diagnostics) this.diagnostics.counts.superseded++; this.pending.delete(sequence); }
          if (sent?.kind === 'neutral' && this.recovering) {
            this.recovering = false;
            this.update({ ...this.view, detail: 'Connected · Xbox gamepad' });
          }
          this.completeProfileSelection();
          this.drain();
        }
      } catch { this.disconnect('Receiver protocol error'); }
    });
  }
  subscribeProfile = listener => { this.profileListeners.add(listener); return () => { this.profileListeners.delete(listener); }; };
  profileSnapshot = () => this.layout;
  receiveLayout(message) {
    if (this.view.phase !== 'connected' || !Number.isSafeInteger(message.revision) || message.revision < 1) throw Error('Invalid layout revision');
    if (message.revision <= this.layout.revision) throw Error('Stale layout revision');
    const profile = assertProfile(message.profile);
    this.layoutPending = true;
    this.outbox = [];
    this.recovering = true;
    this.lease = null;
    this.pending.clear();
    this.state = neutralState();
    this.lastAck = this.now();
    for (const reset of this.resetListeners) reset();
    this.layout = { revision: message.revision, profile };
    for (const listener of this.profileListeners) listener();
  }
  acknowledgeLayout(revision) {
    if (!this.layoutPending || revision !== this.layout.revision || this.view.phase !== 'connected') return;
    if (!this.native.send(JSON.stringify({ type: 'layout-ready', revision }))) { this.disconnect('Could not activate layout', { keepPairing: true }); return; }
    this.layoutPending = false;
    // The receiver supplies a fresh lease after it accepts this acknowledgement.
  }
  subscribe = listener => { this.listeners.add(listener); return () => { this.listeners.delete(listener); }; };
  snapshot = () => this.view;
  update(view) { this.view = view; for (const listener of this.listeners) listener(); }
  async connect(value) {
    const invitation = parseInvitation(value);
    return this.open(invitation);
  }
  async open(invitation) {
    const attempt = ++this.attempt;
    await this.beforeConnect();
    if (attempt !== this.attempt) return;
    this.disconnect(undefined, { keepPairing: !!invitation.reconnectToken });
    this.invitation = invitation; this.sequence = 0;
    this.update({ phase: 'connecting', detail: 'Connecting securely…', rtt: null, chat: false });
    try {
      this.session = this.native.connect(invitation.url, invitation.pin);
      if (typeof this.session !== 'string' || !this.session) throw new Error('Invalid native connection');
      this.timer = this.timers.setTimeout(() => this.disconnect('Could not reach computer. Check Wi-Fi and try again.', { keepPairing: true }), 5000);
    } catch (error) { this.disconnect('Could not connect. Check Wi-Fi and try again.', { keepPairing: true }); throw error; }
  }
  savePairing(value) {
    // Serialize writes so disconnect cannot be undone by an older save finishing late.
    this.storageWrite = this.storageWrite.catch(() => {}).then(() => this.pairingStorage?.save(value));
    void this.storageWrite.catch(() => {
      this.update({ ...this.view, detail: 'Connected · could not remember computer; pair again after restart' });
    });
  }
  suspend() { this.pausePlay(); this.disconnect('Practice · Computer disconnected', { keepPairing: true }); }
  async reconnect() {
    if (this.view.phase !== 'offline') return;
    const attempt = this.attempt;
    await this.storageWrite.catch(() => {});
    const value = this.remembered ?? await this.pairingStorage?.load();
    if (attempt !== this.attempt || this.view.phase !== 'offline' || !value) return;
    try {
      parseReceiverEndpoint(value.url);
      if (!/^[a-f0-9]{64}$/.test(value.pin) || !/^[a-f0-9]{64}$/.test(value.reconnectToken)) throw Error('Invalid remembered computer');
    } catch { this.remembered = null; this.savePairing(null); return; }
    this.remembered = value;
    return this.open(value);
  }
  requestProfiles() { return this.profileOperation('profiles-list'); }
  selectProfile(profile, expectedActivationRevision) {
    for (const reset of this.resetListeners) reset();
    return this.profileOperation('profile-select', { profileId: profile.id, profileRevision: profile.revision, expectedActivationRevision });
  }
  adoptProfile(profile, source, expectedActivationRevision) {
    if (!this.cloudAdoptionSupported) return Promise.reject(Error('Update your receiver to use cloud controllers.'));
    const checked = assertProfile(profile);
    if (source.profileId !== checked.id || !Number.isSafeInteger(source.revision) || source.revision < 1) return Promise.reject(Error('Invalid cloud revision.'));
    this.pausePlay();
    return this.profileOperation('profile-adopt', { profile: checked, source: { ...source }, expectedActivationRevision });
  }
  bindingOperation(type, fields) {
    if (this.view.phase !== 'connected') return Promise.reject(Error('Connect your Mac to edit WoW actions.'));
    if (!this.phoneBindingsSupported) return Promise.reject(Error('Update your Mac receiver to edit WoW actions.'));
    if (this.bindingRequest || this.profileRequest) return Promise.reject(Error('A controller request is already in progress.'));
    if (type === 'bindings-copy') this.pausePlay();
    const id = `bindings-${++this.profileSequence}`;
    return new Promise((resolve, reject) => {
      const timer = this.timers.setTimeout(() => this.finishBindingRequest(Error('Could not confirm the request. Refresh and try again.')), 10000);
      this.bindingRequest = { id, resolve, reject, timer };
      if (!this.native.send(JSON.stringify({ type, id, ...fields, lease: this.lease }))) this.finishBindingRequest(Error('Could not reach your Mac.'));
    });
  }
  finishBindingRequest(error, data = null) {
    const request = this.bindingRequest;
    if (!request) return;
    this.bindingRequest = null;
    this.timers.clearTimeout(request.timer);
    if (error) request.reject(error); else request.resolve(data);
  }
  /** @param {number} [offset] @param {string} [snapshotId] */
  readBindings(offset = 0, snapshotId = undefined) { return this.bindingOperation('bindings-read', { offset, ...(snapshotId ? { snapshotId } : {}) }); }
  copyBindingPlan(plan) { return this.bindingOperation('bindings-copy', { plan }); }
  savePhoneProfile(profile, expectedActivationRevision, expectedProfileRevision = 0) {
    if (!this.phoneProfileSaveSupported) return Promise.reject(Error('Update your Mac receiver to use edited layouts.'));
    const checked = assertProfile(profile);
    if (!/^phone-[a-f0-9]{32}$/.test(checked.id)) return Promise.reject(Error('Invalid edited layout ID.'));
    this.pausePlay();
    return this.profileOperation('profile-save', { profile: checked, expectedActivationRevision, expectedProfileRevision });
  }
  profileOperation(operation, fields = {}) {
    if (this.view.phase !== 'connected') return Promise.reject(Error('Connect your computer to see saved profiles.'));
    if (!this.profilesSupported) return Promise.reject(Error('Update your receiver to choose profiles here.'));
    if (this.profileRequest || this.bindingRequest) return Promise.reject(Error('A profile request is already in progress.'));
    const id = `profiles-${++this.profileSequence}`;
    return new Promise((resolve, reject) => {
      const timer = this.timers.setTimeout(() => this.finishProfileRequest(Error('Could not confirm the profile. Refresh and try again.')), 7000);
      this.profileRequest = { id, operation, profileId: fields.profileId ?? fields.profile?.id, source: fields.source, profile: fields.profile, result: null, resolve, reject, timer };
      if (!this.native.send(JSON.stringify({ type: operation, id, ...fields, lease: this.lease }))) this.finishProfileRequest(Error('Could not reach your computer.'));
    });
  }
  completeProfileSelection() {
    const r = this.profileRequest;
    if (['profile-select', 'profile-adopt', 'profile-save'].includes(r?.operation) && r.result && this.layout.profile.id === r.profileId && this.layout.revision === r.result.activationRevision && !this.layoutPending && !this.recovering) {
      if (r.profile && canonical({ ...this.layout.profile, id: r.profile.id }) !== canonical(r.profile)) this.finishProfileRequest(Error('The Mac activated a different controller. Refresh and try again.'));
      else this.finishProfileRequest();
    }
  }
  /** @param {Error | null} [error] */
  finishProfileRequest(error = null) {
    const request = this.profileRequest;
    if (!request) return;
    this.profileRequest = null;
    this.timers.clearTimeout(request.timer);
    if (error) request.reject(error); else request.resolve(request.result);
  }
  sendChat(text, channel) {
    if (!this.canPlay) return Promise.reject(Error('Start your demo or unlock Pro to send chat.'));
    const error = chatValidation(text, channel);
    if (error) return Promise.reject(Error(error));
    if (this.view.phase !== 'connected' || !this.view.chat || !this.lease || this.layoutPending) return Promise.reject(Error('Connect to an updated receiver to send chat.'));
    if (this.chatRequest) return Promise.reject(Error('A message is already being delivered.'));
    const id = `${this.session}-chat-${++this.chatSequence}`;
    return new Promise((resolve, reject) => {
      const timer = this.timers.setTimeout(() => {
        this.chatRequest = null;
        reject(Error('Delivery could not be confirmed. Check WoW before sending again.'));
      }, 5000);
      this.chatRequest = { id, resolve, reject, timer };
      if (!this.native.send(JSON.stringify({ type: 'chat', id, text: text.trim(), channel, lease: this.lease, revision: this.layout.revision }))) {
        this.timers.clearTimeout(timer); this.chatRequest = null;
        reject(Error('Connection lost. Delivery could not be confirmed; check WoW before sending again.'));
      }
    });
  }
  withTouch(action) {
    this.inputTime = this.now();
    try { action(); } finally { this.inputTime = null; }
  }
  submit = (state, kind = this.inputTime == null ? 'neutral' : 'touch') => {
    if ((!this.canPlay || this.recovering) && Object.values(state).some(value => value !== 0)) return;
    this.state = state;
    if (this.view.phase !== 'connected' || !this.lease || this.layoutPending) return;
    const item = { state: { ...state }, kind, at: this.inputTime ?? this.now() };
    // Preserve digital edges; only replace consecutive snapshots with the same
    // button/trigger ownership. Motion and duplicate heartbeats cannot flood native sends.
    const last = this.outbox.at(-1);
    if (last && last.state.buttons === state.buttons && (last.state.lt > 0) === (state.lt > 0) && (last.state.rt > 0) === (state.rt > 0)) {
      if (kind === 'heartbeat' && last.kind !== 'heartbeat') return;
      this.outbox[this.outbox.length - 1] = item;
    } else this.outbox.push(item);
    if (this.outbox.length > 64) { this.disconnect('Input queue overloaded · controls released', { keepPairing: true }); return; }
    this.drain();
  };
  drain() {
    const nativeCapacity = typeof this.native.canSendInput === 'function';
    while (this.view.phase === 'connected' && this.lease && !this.layoutPending && this.outbox.length) {
      if (nativeCapacity && !this.native.canSendInput(this.inputTransport)) {
        if (!this.retryTimer) this.retryTimer = this.timers.setTimeout(() => { this.retryTimer = null; this.drain(); }, 8);
        return;
      }
      if (!nativeCapacity && this.pending.size >= 4) return; // Older installed native modules.
      if (this.pending.size >= 256) { this.disconnect('Input acknowledgements stalled · controls released', { keepPairing: true }); return; }
      const item = this.outbox.shift();
      // Never replay an old press after a network pause. Recovery cancels ownership.
      if (this.now() - item.at > 150) {
        this.outbox = []; this.state = neutralState(); this.recovering = true;
        for (const reset of this.resetListeners) reset();
        this.outbox = [{ state: neutralState(), kind: 'neutral', at: this.now() }];
        continue;
      }
      this.sendInput(item);
    }
  }
  sendInput({ state, kind, at }) {
    const sequence = ++this.sequence;
    const timing = { js: at, native: NaN, kind, transport: this.inputTransport };
    this.pending.set(sequence, timing);
    const text = JSON.stringify({type:'input', seq:sequence, lease:this.lease, revision:this.layout.revision, state});
    let sent;
    if (this.diagnostics) this.diagnostics.counts.sent++;
    if (this.inputTransport === 'udp') { timing.native = this.native.sendDatagram(text); sent = timing.native >= 0; }
    else if (this.diagnostics) { timing.native = this.native.sendTimed(text); sent = timing.native >= 0; }
    else sent = this.native.send(text);
    if (!sent) this.disconnect('Connection stalled · controls released', { keepPairing: true });
  }
  disconnect(detail = 'Practice · Computer not connected', { keepLayout = false, keepPairing = false } = {}) {
    if (!keepPairing) { this.remembered = null; this.savePairing(null); }
    const connected = this.view.phase === 'connected';
    ++this.attempt;
    // Invalidate the bridge identity before cancelling: queued callbacks from the
    // previous socket must never mutate a replacement connection.
    this.session = null;
    if (this.timer) { this.timers.clearInterval(this.timer); this.timers.clearTimeout(this.timer); this.timer = null; }
    if (this.retryTimer) { this.timers.clearTimeout(this.retryTimer); this.retryTimer = null; }
    this.diagnostics?.flush(); this.diagnostics = null;
    this.inputTransport = 'wss'; this.udpOffered = false;
    this.outbox = []; this.recovering = false;
    this.layoutPending = false;
    this.setAccess(null);
    this.layout = { revision: 0, profile: assertProfile(keepLayout ? this.layout.profile : defaultProfile) };
    for (const listener of this.profileListeners) listener();
    this.lease = null; this.invitation = null; this.state = neutralState(); this.pending.clear();
    this.profilesSupported = false;
    this.cloudAdoptionSupported = false;
    this.phoneProfileSaveSupported = false;
    this.phoneBindingsSupported = false;
    this.finishBindingRequest(Error('Connection closed. Refresh your WoW actions.'));
    this.finishProfileRequest(Error('Disconnected from your computer.'));
    if (this.chatRequest) { this.timers.clearTimeout(this.chatRequest.timer); this.chatRequest.reject(Error('Disconnected. Check WoW before sending again.')); this.chatRequest = null; }
    this.update({phase:'offline',detail,rtt:null,chat:false});
    for (const reset of this.resetListeners) reset();
    if (connected) this.native.send(JSON.stringify({type:'bye'}));
    this.native.disconnect();
  }
}

export function utf8Length(text) {
  return [...text].reduce((count, character) => {
    const point = character.codePointAt(0) ?? 0;
    return count + (point < 0x80 ? 1 : point < 0x800 ? 2 : point < 0x10000 ? 3 : 4);
  }, 0);
}
export function chatValidation(text, channel) {
  if (!['say', 'party', 'raid', 'guild', 'instance'].includes(channel)) return 'Choose a chat channel.';
  if (typeof text !== 'string' || !text.trim()) return 'Type or dictate a message first.';
  if (/[\p{Cc}\p{Zl}\p{Zp}]/u.test(text)) return 'Use a single line without control characters.';
  if (utf8Length(text) > 240) return 'Keep your message within 240 UTF-8 bytes.';
  return null;
}
