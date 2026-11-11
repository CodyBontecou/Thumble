import definitions from './desktop-keys.json' with { type: 'json' };

export const desktopKeys = Object.freeze(definitions.map(key => `key:${key.code}`));
export const desktopLabels = Object.freeze(Object.fromEntries(definitions.map(key => [`key:${key.code}`, key.label])));
export const mouseOutputs = Object.freeze(['mouse:left', 'mouse:right', 'mouse:middle']);
export const desktopTypes = Object.freeze(['key', 'mouse', 'trackpad']);
export const hasDesktopInput = profile => profile?.controls.some(control => desktopTypes.includes(control.type));
export const neutralDesktop = () => ({ keys: [], buttons: 0, x: 0, y: 0, scrollX: 0, scrollY: 0 });
export const isNeutralInput = state => !state.buttons && !state.lx && !state.ly && !state.rx && !state.ry && !state.lt && !state.rt && (!state.desktop || (!state.desktop.keys.length && !state.desktop.buttons && !state.desktop.x && !state.desktop.y && !state.desktop.scrollX && !state.desktop.scrollY));
