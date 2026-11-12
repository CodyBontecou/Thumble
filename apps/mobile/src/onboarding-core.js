import { AI_CONTROLLER_GENERATOR_ENABLED } from './features.js';

export const initialSetup = () => ({
  version: 2, welcomeSeen: false, dismissed: false, paired: false, controlsTested: false, wowTested: false,
  personalized: false, agentVerified: false, agentCode: '', layoutMode: 'consoleport',
  buttonSize: 'larger', movementSide: 'left', character: '', profileId: '', sourceProfileId: '',
  wowClient: '', consolePortReady: false, wowChecks: {}, controlsCheckContext: '', wowCheckContext: '',
  wowSyncStatus: '', wowSyncContext: '', tourDone: false, tourStage: '',
});
export function normalizeSetup(value) {
  const result = initialSetup();
  if (!value || value.version !== 2) return result;
  for (const key of ['welcomeSeen', 'dismissed', 'paired', 'controlsTested', 'wowTested', 'personalized', 'agentVerified', 'consolePortReady', 'tourDone']) result[key] = value[key] === true;
  if (['connect'].includes(value.tourStage)) result.tourStage = value.tourStage;
  // Players who already finished or dismissed the old setup skip the new tour.
  if (!('tourDone' in value) && (result.dismissed || (result.paired && result.controlsTested))) result.tourDone = true;
  for (const [key, choices] of Object.entries({ layoutMode: ['familiar', 'consoleport', 'character'], buttonSize: ['standard', 'larger'], movementSide: ['left', 'right'] })) {
    if (choices.includes(value[key])) result[key] = value[key];
  }
  if (typeof value.character === 'string') result.character = value.character.slice(0, 80);
  for (const key of ['controlsCheckContext', 'wowCheckContext', 'wowSyncContext']) if (typeof value[key] === 'string' && /^[a-zA-Z0-9:-]{1,250}$/.test(value[key])) result[key] = value[key];
  if (['confirmed', 'skipped'].includes(value.wowSyncStatus)) result.wowSyncStatus = value.wowSyncStatus;
  if (WOW_CLIENTS.some(client => client.id === value.wowClient)) result.wowClient = value.wowClient;
  result.wowChecks = Object.fromEntries(WOW_CHECKS.map(check => [check.id, value.wowChecks?.[check.id] === true]));
  if (typeof value.agentCode === 'string' && /^[a-f0-9]{12}$/.test(value.agentCode)) result.agentCode = value.agentCode;
  for (const key of ['profileId', 'sourceProfileId']) if (typeof value[key] === 'string' && /^[a-z0-9][a-z0-9-]{0,63}$/.test(value[key])) result[key] = value[key];
  return result;
}
export const setupComplete = state => state.paired && state.controlsTested && state.wowTested && (!AI_CONTROLLER_GENERATOR_ENABLED || state.personalized);
export const matchesAgentCheck = (catalog, code) => /^[a-f0-9]{12}$/.test(code) && catalog?.agentCheckSupported === true && catalog.agentConnection?.code === code && Number.isFinite(catalog.agentConnection.ageSeconds) && catalog.agentConnection.ageSeconds >= 0 && catalog.agentConnection.ageSeconds <= 600;
export const firstLayoutDelivered = (state, network, layout, pending, recovering) => !!state.profileId && network.phase === 'connected' && layout.profile.id === state.profileId && layout.revision > 0 && !pending && !recovering;

export const WOW_CLIENTS = [
  { id: 'forever', name: 'WoW: Forever', detail: 'Built-in gamepad support · no addons needed', native: true },
  { id: 'retail', name: 'World of Warcraft', detail: 'The current Retail installation' },
  { id: 'classic', name: 'WoW Classic', detail: 'Your progression Classic installation' },
  { id: 'classic-era', name: 'WoW Classic Era', detail: 'Era, Hardcore or a seasonal Era realm' },
  { id: 'other', name: 'Another WoW installation', detail: 'Check that ConsolePort supports the client you launch' },
];
export const WOW_CHECKS = [
  { id: 'movement', title: 'Move and stop', detail: 'Walk with the movement stick. Release it and check that your character stops.' },
  { id: 'camera', title: 'Look in every direction', detail: 'Try the camera stick. If a direction feels reversed, adjust Stick calibration from the Thumble menu.' },
  { id: 'action', title: 'Use a bound action', detail: 'Try jump or a learned ability using the button the game shows for it.' },
  { id: 'modifier', title: 'Hold a modifier and act', detail: 'Hold a shoulder or trigger modifier, press an action, then release both. Confirm the intended action and return to the base layer.' },
  { id: 'menu', title: 'Navigate and return', detail: 'Open a game menu, move through it and close it. Keep keyboard and mouse within reach.' },
];
export const wowClientName = state => WOW_CLIENTS.find(client => client.id === state.wowClient)?.name || 'your WoW installation';
/** WoW: Forever reads the gamepad natively: no ConsolePort, no Thumble addon, no spell-label sync. */
export const nativeGamepad = state => WOW_CLIENTS.find(client => client.id === state?.wowClient)?.native === true;
/** Setup stages for the chosen client; native clients skip addon and label sync. */
export const wowSetupStages = state => nativeGamepad(state) ? ['client', 'connect', 'game', 'ready'] : ['client', 'connect', 'addon', 'sync', 'game', 'ready'];
/** @param {any} state @param {boolean} online @param {{controlKey:string, wowKey:string} | null} [context] */
export function wowSetupStep(state, online, context = null) {
  if (!state.wowClient) return 'client';
  if (!online) return 'connect';
  const native = nativeGamepad(state);
  if (!native && !state.consolePortReady) return 'addon';
  if (state.wowTested && state.controlsTested && (!context || (context.controlKey && state.controlsCheckContext === context.controlKey && context.wowKey && state.wowCheckContext === context.wowKey))) return 'ready';
  if (!native && !wowSyncResolved(state, context)) return 'sync';
  return 'game';
}
/** @param {any} state @param {{controlKey:string, wowKey:string} | null} context */
const wowSyncResolved = (state, context) => ['confirmed', 'skipped'].includes(state.wowSyncStatus) && !!state.wowSyncContext && (!context || state.wowSyncContext === context.wowKey);

/** @param {any} state @param {boolean} online @param {{controlKey:string, wowKey:string} | null} [context] */
export const canCompleteWowSetup = (state, online, context = null) => online && !!state.wowClient && (nativeGamepad(state) || (state.consolePortReady && wowSyncResolved(state, context))) && (!context || (!!context.controlKey && !!context.wowKey && state.wowCheckContext === context.wowKey)) && WOW_CHECKS.every(check => state.wowChecks?.[check.id] === true);

/**
 * The three setup lights, each detected rather than self-reported:
 * paired (receiver handshake), gamepad live (connected with input recovered)
 * and spell labels (ConsolePort sync is following this controller, which only
 * happens when ConsolePort and the Thumble addon both work). A player may skip
 * labels for the current context and play with button names. WoW: Forever has
 * built-in gamepad support and no label sync, so its third light is the game
 * choice itself.
 * @param {{ state: any, online: boolean, recovering: boolean, labelsFollowing: boolean, context: string }} input
 */
export function setupSignals({ state, online, recovering, labelsFollowing, context }) {
  const labelsSkipped = state.wowSyncStatus === 'skipped' && !!context && state.wowSyncContext === context;
  const native = nativeGamepad(state);
  const done = [state.paired || online, online && !recovering, online && !recovering && (native || labelsFollowing || labelsSkipped)];
  const stage = done.indexOf(false) === -1 ? 3 : done.indexOf(false);
  return { done, stage, labelsSkipped, native };
}
/** Practice completion records the same milestones as the former five checks. */
export const PRACTICE_STEPS = [
  { id: 'movement', title: 'Push Move forward, then let go. You should stop.', fix: 'Still moving? Check the receiver is running, then try again.' },
  { id: 'camera', title: 'Use Look to turn the camera all the way around.', fix: 'Reversed? Turn on Invert look in Stick calibration.' },
  { id: 'action', title: 'Press A. Jump is on A by default.', fix: 'No jump? Choose Xbox-style buttons in the game’s gamepad settings or ConsolePort’s setup.' },
  { id: 'modifier', title: 'Hold a modifier, press A, then release both.', fix: 'Nothing on that layer? Bind it in the game’s gamepad settings or in ConsolePort, then /reload.' },
  { id: 'menu', title: 'Press Menu to open the game menu, then close it.', fix: 'Keep a keyboard nearby for anything the gamepad can’t reach.' },
];

export function cloudLayoutPrompt(state, session) {
  const wow = state.layoutMode === 'consoleport' || state.layoutMode === 'character';
  const context = nativeGamepad(state)
    ? `I play ${wowClientName(state)} with its built-in gamepad support (no ConsolePort or addons). Build a complete standard gamepad layout for WoW: movement and camera sticks, A/B/X/Y, shoulders, both triggers, D-pad, stick clicks, View and Menu. Keep shoulder/trigger combinations reachable while moving. Preserve standard Xbox-style gamepad outputs; the game owns the in-game action bindings. Label buttons by their gamepad names. Do not invent spells or claim a binding is applied.`
    : wow
    ? `I play ${wowClientName(state)} with ConsolePort${state.character ? `. Character/class note (user supplied, not a verified export): ${JSON.stringify(state.character)}` : ''}. Build a complete standard gamepad layout for WoW: movement and camera sticks, A/B/X/Y, shoulders, both triggers, D-pad, stick clicks, View and Menu. Keep shoulder/trigger modifier combinations reachable while moving. Preserve standard gamepad outputs; ConsolePort owns the in-game action bindings. Label buttons by their gamepad names unless I provide a fresh verified character export. Do not invent spells, modifier assignments or claim a binding is applied. Ask which character export I want to share before using character data. The hosted service does not expose the local Thumble import/mirror/binding tools; those require a separate local agent handoff and player Review and Apply in-game.`
    : 'Build a comfortable controller with familiar gamepad mappings.';
  return `Connect to my Thumble MCP service at ${session.mcpUrl || `${session.service}/mcp`} and sign in to the same account as my phone. Read profile_schema and list_devices before designing. ${context}\nI prefer ${state.buttonSize === 'larger' ? 'larger action buttons' : 'standard-size buttons'} and movement on the ${state.movementSide}. Use the phone viewport, keep every control inside the usable area and prevent overlapping touch targets. Validate the complete profile with deviceId for this phone: use at least 48 logical points on both target dimensions and 96 for stick diameters, with no overlapping touch targets or top Chat/menu obstruction. Pass deviceId when saving a new profile ID without overwriting my existing controllers. Deliver that exact saved revision to device ${session.device.id} (${JSON.stringify(session.device.name)}) using a fresh requestId. Check delivery_status; queued and received are not rendered. I will open the downloaded controller in practice or explicitly choose Use this controller on computer while paired. A rendered receipt confirms the phone layout, not working computer input or WoW bindings. Every gameplay press stays mine.`;
}

// Serialize reads and writes so rapid edits cannot lose another milestone.
export function createOnboardingStore(storage) {
  let state = { ...initialSetup(), loaded: false };
  let loading;
  /** @type {Promise<any>} */
  let writes = Promise.resolve();
  const listeners = new Set();
  const publish = next => { state = next; for (const listener of listeners) listener(); };
  const load = () => {
    if (state.loaded) return Promise.resolve(state);
    if (!loading) loading = (async () => {
      const raw = await storage.read();
      const legacy = !raw && await storage.legacyComplete();
      const value = raw ? normalizeSetup(JSON.parse(raw)) : { ...initialSetup(), welcomeSeen: legacy, dismissed: legacy };
      publish({ ...value, loaded: true });
      return state;
    })().catch(error => { loading = undefined; throw error; });
    return loading;
  };
  return {
    subscribe: listener => { listeners.add(listener); return () => listeners.delete(listener); },
    snapshot: () => state,
    load,
    update(patch) {
      const operation = writes.catch(() => {}).then(async () => {
        await load();
        const changes = typeof patch === 'function' ? patch(state) : patch;
        const next = normalizeSetup({ ...state, ...changes });
        await storage.write(JSON.stringify(next));
        publish({ ...next, loaded: true });
        return state;
      });
      writes = operation;
      return operation;
    },
    async isComplete() { const value = await load(); return value.dismissed || setupComplete(value); },
  };
}
export function firstLayoutPrompt(state, sourceProfileId) {
  const startingPoint = nativeGamepad(state)
    ? `I play ${wowClientName(state)} with its built-in gamepad support. Start from the familiar Xbox-style controller, preserving its gamepad outputs; the game owns the in-game bindings.`
    : state.layoutMode === 'consoleport'
    ? `I play ${wowClientName(state)}. Mirror my exported ConsolePort layout with mirror_consoleport, using my current phone profile as the source. Ask for a fresh Thumble character export if needed; do not invent exported positions.`
    : state.layoutMode === 'character'
      ? `Build around my character${state.character ? ` (${state.character})` : ''}. Read my imported character snapshot or ask me for a fresh Thumble export. Use only learned spells; leave ambiguous choices unresolved.`
      : 'Start from the familiar Xbox-style controller, preserving its gamepad outputs.';
  return `Help me create my first Thumble layout. First call agent_connection_check with code "${state.agentCode}", then read controller_status, profile_schema and current profile revisions.\n${startingPoint}\nMy current phone profile ID is "${sourceProfileId}". Use "${state.profileId}" as the new profile ID and do not overwrite another profile. I prefer ${state.buttonSize === 'larger' ? 'larger action buttons' : 'standard-size buttons'} and movement on the ${state.movementSide}. Keep controls reachable and non-overlapping.\nValidate and save the complete profile. Custom layouts are included in the demo; Pro removes the play-time limit. If game bindings need changing, propose them and guide me through in-game Review and Apply; import the verified result before syncing labels. Activate the saved revision on my paired phone, then check controller_status. Only say it arrived when the matching revision is acknowledged. Every gameplay press stays mine.`;
}
