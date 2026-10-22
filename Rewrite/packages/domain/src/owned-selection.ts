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
/** Resolve the two known profile maps independently, sharing the exact retained
 * fallback and owner checks between selection and duplication. */
function profileBindingMaps(
  source: LosslessJson,
  profileIndex: number,
  profileIds: ReadonlySet<string>,
) {
  const profile = source.get(`/profiles/${profileIndex}`)!,
    storedId = profile.get("/id")!.stringValue!,
    selectedId = uuid(storedId);
  const controls = readOwnedProfileControls(profile),
    owners = new Set(controls.map((control) => control.id));
  let fallbacks: readonly [LosslessJson, LosslessJson] | undefined;
  return (
    [
      ["profileKeyBindings", "keyBindings", true, 0],
      ["profileOutputBindings", "outputBindings", false, 1],
    ] as const
  ).map(([perProfile, root, keyboard, fallbackIndex]) => {
    const map = source.get("/" + perProfile) ?? LosslessJson.parse("{}"),
      seen = new Set<string>();
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
    return { map, chosen, foundKey: found?.[0], storedId, perProfile, root };
  });
}
/** Copy source-profile bindings into a new profile identity without changing the
 * source aliases, direct root mirrors, or active/default selectors. */
export function cloneOwnedProfileBindings(
  source: LosslessJson,
  profileIndex: number,
  newProfileId: string,
  profileIds: ReadonlySet<string>,
): LosslessJson {
  const id = uuid(newProfileId);
  if (profileIds.has(id)) throw new Error("duplicate_profile_id");
  let result = source;
  for (const { map, chosen, perProfile } of profileBindingMaps(
    source,
    profileIndex,
    profileIds,
  ))
    result = result.set(
      "/" + perProfile,
      map.set("/" + segment(id), chosen.text()).text(),
    );
  return result;
}
/** Source-only selected binding synchronization; no asset materialization or
 * runtime publication. Existing map values retain every opaque source member. */
export function synchronizeOwnedActiveBindings(
  source: LosslessJson,
  profileIndex: number,
  profileIds: ReadonlySet<string>,
): LosslessJson {
  let result = source;
  for (const resolved of profileBindingMaps(source, profileIndex, profileIds)) {
    const { chosen, foundKey, storedId, perProfile, root } = resolved;
    let map = resolved.map;
    if (foundKey !== undefined && foundKey !== storedId)
      map = map.remove("/" + segment(foundKey));
    if (foundKey === undefined || foundKey !== storedId)
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
