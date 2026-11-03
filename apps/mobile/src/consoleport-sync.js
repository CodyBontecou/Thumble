const buttonNames = { lt: 'LT', rt: 'RT', lb: 'LB', rb: 'RB', ls: 'L3', rs: 'R3', back: 'View', start: 'Menu', none: 'None' };

export function usesPhoneCalibration(profile) {
  return profile.id === 'consoleport-standard' || (profile.theme === 'consoleport' && /^consoleport-[a-f0-9]{24}$/.test(profile.id));
}

/** Optional receiver metadata is display-only; it never transforms controller input. */
export function consolePortSyncView({ online, catalog, profile, error = '', loading = false }) {
  const bridge = catalog?.consolePortBridge;
  const sync = catalog?.consolePortSync;
  const valid = sync && typeof sync.characterName === 'string' && sync.characterName.length > 0 && sync.characterName.length <= 80
    && Number.isFinite(sync.exportedAt) && sync.exportedAt > 0 && sync.exportedAt <= 8_640_000_000_000
    && typeof sync.profileId === 'string' && typeof sync.following === 'boolean';
  const following = online && !error && bridge?.enabled === true && valid && sync.following && sync.profileId === profile.id;
  let title = 'Waiting for ConsolePort';
  let detail = 'In WoW, type /reload after changing your bindings. Leave Automatically sync ConsolePort enabled in the Mac receiver.';
  if (!online) { title = 'Connect your Mac'; detail = 'Connect to see your character and the latest ConsolePort sync.'; }
  else if (error) { title = 'Sync status unavailable'; detail = error; }
  else if (loading && !catalog) { title = 'Checking ConsolePort…'; detail = 'Reading sync status from your Mac.'; }
  else if (!bridge || typeof bridge.enabled !== 'boolean') { title = 'Update your Mac receiver'; detail = 'This receiver can’t report ConsolePort sync status. Your controller still works.'; }
  else if (!bridge.enabled) { title = 'ConsolePort sync is off'; detail = 'Enable Automatically sync ConsolePort in the Mac receiver, then type /reload in WoW.'; }
  else if (following) { title = 'Following ConsolePort'; detail = 'Bindings, spell labels and modifier layers follow your character after /reload.'; }
  else if (valid) { title = 'Another controller is active'; detail = 'Choose your character’s ConsolePort profile, or use built-in ConsolePort controls and type /reload in WoW.'; }
  const modifiers = valid ? ['shift', 'ctrl', 'alt'].flatMap(key => {
    const value = sync.modifiers?.[key];
    return typeof value === 'string' && /^(a|b|x|y|lt|rt|lb|rb|ls|rs|back|start|up|down|left|right|guide|none)$/.test(value)
      ? [{ label: key === 'ctrl' ? 'Control' : key[0].toUpperCase() + key.slice(1), value: buttonNames[value] ?? value.toUpperCase() }] : [];
  }) : [];
  return { title, detail, following, character: valid ? sync.characterName : '', exportedAt: valid ? sync.exportedAt : null, modifiers,
    receiverDetail: online && typeof bridge?.detail === 'string' && bridge.detail.length <= 512 ? bridge.detail : '' };
}
