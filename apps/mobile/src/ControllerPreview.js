import { useState, useSyncExternalStore } from 'react';
import { Pressable, Text, View } from 'react-native';
import { BUTTONS, consolePortProfile, controlDisplay, modifierPrefix } from '@tapping/controller';
import { ControlArtwork, controllerStyles as s } from './ControllerScreen';
import { connection } from './connection';

const BASE = { width: 760, height: 340 };
const glyph = { back: '▧', start: '≡' };
// Modifier keys held in the preview: synced profiles name them, the built-in
// ConsolePort controller falls back to the LT/RT chord.
const modifierKeys = profile => profile.theme === 'consoleport' && profile.modifiers === undefined ? ['lt', 'rt'] : Object.values(profile.modifiers ?? {}).filter(key => key !== 'none');

/**
 * A faithful, input-free drawing of the ConsolePort controller. It renders at a
 * fixed logical size and scales to fit, so paywall previews match the real pad.
 * @param {{ width: number, height: number, interactive?: boolean }} props
 */
export default function ControllerPreview({ width, height, interactive = false }) {
  const layout = useSyncExternalStore(connection.subscribeProfile, connection.profileSnapshot);
  const profile = layout.revision > 0 && layout.profile.theme === 'consoleport' ? layout.profile : consolePortProfile;
  const [held, setHeld] = useState(/** @type {string[]} */ ([]));
  const scale = Math.min(width / BASE.width, height / BASE.height);
  const state = { buttons: held.filter(key => BUTTONS.includes(key)).reduce((bits, key) => bits | (1 << BUTTONS.indexOf(key)), 0), lt: held.includes('lt') ? 1 : 0, rt: held.includes('rt') ? 1 : 0 };
  const prefix = modifierPrefix(profile, state);
  const modifiers = modifierKeys(profile);
  const toggle = id => setHeld(current => current.includes(id) ? current.filter(key => key !== id) : [...current, id]);
  return <View style={{ width, height, overflow: 'hidden', backgroundColor: '#1C1C1E' }} accessible={!interactive} accessibilityLabel="Preview of the ConsolePort controller">
    <View style={{ position: 'absolute', width: BASE.width, height: BASE.height, left: (width - BASE.width) / 2, top: (height - BASE.height) / 2, transform: [{ scale }] }}>
      {profile.controls.map(control => {
        const { frame } = control;
        const w = frame.width * BASE.width, h = frame.height * BASE.height, d = Math.min(w, h);
        const box = { position: /** @type {const} */ ('absolute'), left: frame.x * BASE.width, top: frame.y * BASE.height, width: w, height: h, alignItems: /** @type {const} */ ('center'), justifyContent: /** @type {const} */ ('center') };
        if (control.type === 'stick') return <View key={control.id} style={box}>
          <View style={[s.well, { width: d, height: d }]}><View style={[s.cap, { width: d * 0.64, height: d * 0.64 }]}><View style={s.grip} /></View><Text style={s.stickLabel}>{control.label}</Text></View>
        </View>;
        if (['key', 'mouse', 'trackpad'].includes(control.type)) return <View key={control.id} style={box}><View style={[s.button, { width: w, height: h, borderRadius: 12 }]}><Text numberOfLines={2} style={s.buttonLabel}>{control.customLabel ?? control.label}</Text></View></View>;
        const display = controlDisplay(control, prefix, profile);
        const isModifier = interactive && modifiers.includes(control.id);
        const on = held.includes(control.id);
        const face = <View style={[s.button, s.consolePortButton, { width: d, height: d }, on && s.active]}>
          {glyph[control.id] && !display.icon ? <Text style={s.buttonLabel}>{glyph[control.id]}</Text> : <ControlArtwork key={`${display.icon ?? ''}:${display.label}`} label={display.label} icon={display.icon} />}
          <Text style={[s.badge, control.color && { color: control.color }]}>{control.badge}</Text>
        </View>;
        return isModifier
          ? <Pressable key={control.id} accessibilityRole="switch" accessibilityLabel={`Hold ${control.badge ?? control.label}`} accessibilityState={{ checked: on }} onPress={() => toggle(control.id)} style={box}>{face}</Pressable>
          : <View key={control.id} style={box} pointerEvents="none">{face}</View>;
      })}
    </View>
  </View>;
}
