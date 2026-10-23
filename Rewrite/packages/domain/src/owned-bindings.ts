import type { LosslessJson } from "@thumble/contracts/json";
import {
  entries,
  field,
  invalidOwned,
  object,
  rows,
  unsigned,
  uuid,
} from "./owned-json.ts";
export type OwnedKeyStroke = Readonly<{ keyCode: number; modifiers: number }>;
export type OwnedKeyBinding = Readonly<
  OwnedKeyStroke & { sequence: readonly OwnedKeyStroke[] | null }
>;
export type OwnedOutput = Readonly<{
  keyboard: OwnedKeyBinding | null;
  gamepadButtons: readonly string[];
}>;
function stroke(value: LosslessJson): OwnedKeyStroke {
  object(value);
  const direct = value.get("/modifiers"),
    shared = value.get("/modifiersRawValue");
  if (direct && shared) invalidOwned();
  return Object.freeze({
    keyCode: unsigned(value.get("/keyCode"), 65535),
    modifiers: direct || shared ? unsigned(direct ?? shared, 255) : 0,
  });
}
export function readOwnedKeyboard(value: LosslessJson): OwnedKeyBinding {
  const first = stroke(value),
    raw = field(value, "sequence");
  const sequence = raw ? Object.freeze(rows(raw, 32).map(stroke)) : null;
  return Object.freeze({ ...first, sequence });
}
export function readOwnedOutput(value: LosslessJson): OwnedOutput {
  object(value);
  const raw = value.get("/gamepadButtons");
  const buttons = new Set<string>();
  if (raw)
    for (const node of rows(raw, 131072)) {
      const name = node.stringValue;
      if (name === undefined) invalidOwned();
      buttons.add(name);
      if (buttons.size > 32) invalidOwned();
    }
  const keyboard = field(value, "keyboard");
  return Object.freeze({
    keyboard: keyboard ? readOwnedKeyboard(keyboard) : null,
    gamepadButtons: Object.freeze([...buttons].sort()),
  });
}
export function validateOwnedBindingMap(
  value: LosslessJson,
  owners: ReadonlySet<string>,
  keyboard: boolean,
): void {
  const seen = new Set<string>();
  for (const [raw, binding] of entries(value, 384)) {
    const id = uuid(raw);
    if (seen.has(id) || !owners.has(id)) invalidOwned();
    seen.add(id);
    if (keyboard) readOwnedKeyboard(binding);
    else readOwnedOutput(binding);
  }
}
export function validateOwnedBindingMaps(
  source: LosslessJson,
  declarations: ReadonlyMap<string, ReadonlySet<string>>,
  activeProfileId: string,
): void {
  for (const [direct, perProfile, keyboard] of [
    ["keyBindings", "profileKeyBindings", true],
    ["outputBindings", "profileOutputBindings", false],
  ] as const) {
    const root = source.get("/" + direct);
    if (root)
      validateOwnedBindingMap(
        root,
        declarations.get(activeProfileId)!,
        keyboard,
      );
    const profiles = source.get("/" + perProfile);
    if (!profiles) continue;
    const seen = new Set<string>();
    for (const [raw, value] of entries(profiles, 512)) {
      const id = uuid(raw),
        owners = declarations.get(id);
      if (seen.has(id) || !owners) invalidOwned();
      seen.add(id);
      validateOwnedBindingMap(value, owners, keyboard);
    }
  }
}
