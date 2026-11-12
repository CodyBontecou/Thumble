// Development-only receiver fixture. This file is never packaged in a receiver.
import { defaultProfile, builtInProfiles } from '../../controller/src/index.js';
import { copy, issues } from './model.js';
let state = {
  simulated: true, scenario: 'disconnected', platform: 'Preview · macOS / Windows / Linux',
  profiles: builtInProfiles.map(profile => ({ profile: copy(profile), revision: 1, editable: false })), active: null, activationRevision: 0,
  receiver: { running: true, connected: false, ready: false, detail: 'Simulated receiver · ready to pair' },
  sync: { detail: 'ConsolePort: waiting for /reload' },
  settings: { syncEnabled: true, startAtLogin: false, wowPaths: [] }, pairing: null,
};
try {
  const saved = JSON.parse(sessionStorage.getItem('thumble-studio-preview'));
  if (saved?.profiles?.length) state = saved;
} catch { /* A corrupt development fixture resets safely. */ }
const persist = () => sessionStorage.setItem('thumble-studio-preview', JSON.stringify(state));
window.thumblePreviewHost = async (operation, payload) => {
  if (operation === 'save') {
    const problems = issues(payload.profile, payload.viewport); if (problems.length) throw Error(problems[0]);
    const entry = state.profiles.find(e => e.profile.id === payload.profile.id);
    if (entry && (!entry.editable || entry.revision !== payload.expectedProfileRevision)) throw Error('This controller changed elsewhere. Reopen it before saving.');
    if (entry) { entry.profile = copy(payload.profile); entry.revision++; }
    else if (payload.expectedProfileRevision === 0) state.profiles.push({ profile: copy(payload.profile), revision: 1, editable: true });
    else throw Error('Controller no longer exists.');
  } else if (operation === 'activate') {
    const entry = state.profiles.find(e => e.profile.id === payload.profileId);
    if (!entry || entry.revision !== payload.profileRevision || state.activationRevision !== payload.expectedActivationRevision) throw Error('Selection changed. Refresh before sending.');
    state.active = { profile: copy(entry.profile), profileRevision: entry.revision, revision: ++state.activationRevision };
    state.receiver.ready = false; state.receiver.layoutAcknowledged = false;
    const revision = state.activationRevision;
    setTimeout(() => { if (state.receiver.connected && revision === state.activationRevision) { state.receiver.ready = true; state.receiver.layoutAcknowledged = true; state.receiver.revision = revision; state.receiver.detail = 'Simulated phone acknowledged the selected controller'; persist(); } }, 1800);
  } else if (operation === 'delete') {
    const index = state.profiles.findIndex(e => e.profile.id === payload.profileId);
    if (index < 0 || !state.profiles[index].editable || state.active?.profile.id === payload.profileId || state.profiles[index].revision !== payload.expectedProfileRevision || payload.expectedActivationRevision !== state.activationRevision) throw Error('Controller changed or is selected. Refresh and try again.');
    state.profiles.splice(index, 1);
  } else if (operation === 'simulate') {
    state.scenario = payload.state;
    state.receiver = { running: payload.state !== 'missing-driver', connected: ['connected', 'pending', 'stale-edit'].includes(payload.state), ready: payload.state === 'connected', detail: payload.state === 'missing-driver' ? 'Gamepad driver unavailable. Open Driver & permissions to finish setup.' : payload.state === 'pending' ? 'Waiting for phone layout acknowledgement' : 'Simulated receiver · '+payload.state };
    if (payload.state === 'stale-edit') {
      const entry = [...state.profiles].reverse().find(e => e.editable);
      if (entry) { entry.revision++; entry.profile.name += ' (phone edit)'; }
    }
  } else if (operation === 'settings') Object.assign(state.settings, payload);
  else if (operation === 'disconnect' || operation === 'forget') Object.assign(state.receiver, { connected: false, ready: false, detail: 'Simulated phone disconnected' });
  else if (operation === 'retry') Object.assign(state.receiver, { running: true, detail: 'Simulated receiver ready' });
  else if (operation === 'choose-wow-folder') state.settings.wowPaths = ['Simulated WoW folder'];
  else if (operation === 'export') {
    const blob = new Blob([JSON.stringify(payload.profile, null, 2)], { type: 'application/json' });
    const link = document.createElement('a'); link.href = URL.createObjectURL(blob); link.download = 'controller.json'; link.click(); setTimeout(() => URL.revokeObjectURL(link.href), 1000);
  } else if (!['snapshot', 'copy-pairing', 'setup-driver'].includes(operation)) throw Error('Unknown preview operation.');
  persist(); return operation === 'export' ? { exported: true } : copy(state);
};
