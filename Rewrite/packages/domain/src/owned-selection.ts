import { LosslessJson } from "@thumble/contracts/json";
import { entries, invalidOwned, uuid } from "./owned-json.ts";
import { readOwnedProfileControls } from "./owned-profile.ts";
import {
  validateOwnedBindingMap,
  type OwnedKeyBinding,
  type OwnedOutput,
} from "./owned-bindings.ts";

const segment = (value: string) =>
  value.replaceAll("~", "~0").replaceAll("/", "~1");
/** Mac's retained initial primary outputs: configured (including explicit empty)
 * overrides default; no mode filtering, part-output merge or global fallback. */
function initialMaps(
  controls: ReturnType<typeof readOwnedProfileControls>,
): readonly [LosslessJson, LosslessJson] {
  const outputs: Record<string, unknown> = Object.create(null),
    keys: Record<string, unknown> = Object.create(null);
  function keyboard(value: OwnedKeyBinding): unknown {
    const strokes = value.sequence?.length ? value.sequence : [value],
      first = strokes[0]!;
    return {
      keyCode: first.keyCode,
      modifiers: first.modifiers,
      ...(strokes.length > 1
        ? {
            sequence: strokes.map((stroke) => ({
              keyCode: stroke.keyCode,
              modifiers: stroke.modifiers,
            })),
          }
        : {}),
    };
  }
  for (const control of controls) {
    const configured =
      control.kind === "text" || control.kind === "decoration"
        ? null
        : control.output;
    const output: OwnedOutput | null = configured ?? control.defaultOutput;
    if (output === null) continue;
    const id = control.id.toUpperCase(),
      key = output.keyboard === null ? undefined : keyboard(output.keyboard);
    outputs[id] = {
      ...(key === undefined ? {} : { keyboard: key }),
      gamepadButtons: output.gamepadButtons,
    };
    if (key !== undefined) keys[id] = key;
  }
  return [
    LosslessJson.parse(JSON.stringify(keys)),
    LosslessJson.parse(JSON.stringify(outputs)),
  ];
}
/** Source-only selected binding synchronization; no asset materialization or
 * runtime publication. Existing map values retain every opaque source member. */
export function synchronizeOwnedActiveBindings(
  source: LosslessJson,
  profileIndex: number,
  profileIds: ReadonlySet<string>,
): LosslessJson {
  const profile = source.get(`/profiles/${profileIndex}`)!,
    idToken = profile.get("/id")!,
    storedId = idToken.stringValue!,
    selectedId = uuid(storedId);
  // A metadata catalog is insufficient for binding fallback or owner checking.
  const controls = readOwnedProfileControls(profile),
    owners = new Set(controls.map((control) => control.id));
  let fallbacks: readonly [LosslessJson, LosslessJson] | undefined,
    result = source;
  for (const [perProfile, root, keyboard, fallbackIndex] of [
    ["profileKeyBindings", "keyBindings", true, 0],
    ["profileOutputBindings", "outputBindings", false, 1],
  ] as const) {
    let map = source.get("/" + perProfile) ?? LosslessJson.parse("{}");
    const seen = new Set<string>();
    let found: readonly [string, LosslessJson] | undefined;
    for (const [key, value] of entries(map, 512)) {
      const id = uuid(key);
      if (seen.has(id) || !profileIds.has(id)) invalidOwned();
      seen.add(id);
      if (id === selectedId) found = [key, value];
    }
    if (!found && !fallbacks) fallbacks = initialMaps(controls);
    const chosen = found ? found[1] : fallbacks![fallbackIndex];
    validateOwnedBindingMap(chosen, owners, keyboard);
    if (found && found[0] !== storedId)
      map = map.remove("/" + segment(found[0]));
    if (!found || found[0] !== storedId)
      map = map.set("/" + segment(storedId), chosen.text());
    for (const [path, value] of [
      ["/" + perProfile, map],
      ["/" + root, chosen],
    ] as const)
      if (result.get(path)?.text() !== value.text())
        result = result.set(path, value.text());
  }
  return result;
}
