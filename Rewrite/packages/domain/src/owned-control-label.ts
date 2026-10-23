import { LosslessJson } from "@thumble/contracts/json";
import {
  decodeConfigurationControlLabelChange,
  type ConfigurationControlLabelChange,
} from "@thumble/contracts/control-label";
import {
  ConfigurationCatalog,
  configurationTimestamp,
} from "./configuration-catalog.ts";
import { OwnedAuthorityDocument } from "./owned-authority.ts";
import { readOwnedProfileControls } from "./owned-profile.ts";
import { uuid, uuidPairs } from "./owned-json.ts";
export type OwnedControlLabelChange = ConfigurationControlLabelChange;

/** Pure user-label authoring. No source activation, binding edits or authority CAS.
 * Stored resource descriptors and generated labels are deliberately untouched. */
export function setOwnedControlLabel(
  source: LosslessJson,
  change: OwnedControlLabelChange,
  updatedAt: string,
): LosslessJson {
  const edit = decodeConfigurationControlLabelChange(change);
  const external = OwnedAuthorityDocument.isAuthority(source);
  const authority = external ? OwnedAuthorityDocument.read(source) : undefined;
  const body = external ? source.get("/document")! : source;
  const catalog = authority?.catalog ?? ConfigurationCatalog.read(body);
  const index = catalog.profiles.findIndex(
    (profile) => profile.id === edit.profileId,
  );
  if (index < 0) throw new Error("profile_not_found");
  const prefix = `${external ? "/document" : ""}/profiles/${index}`;
  const profile = source.get(prefix)!;
  if (
    !readOwnedProfileControls(profile).some(
      (control) => control.id === edit.controlId,
    )
  )
    throw new Error("control_not_found");
  if (
    typeof updatedAt !== "string" ||
    !/^(?:0|[1-9][0-9]{0,18})$/.test(updatedAt)
  )
    throw new Error("invalid_control_label_timestamp");
  configurationTimestamp(LosslessJson.parse(updatedAt));
  const path = prefix + "/customization/labelOverrides";
  const original = source.get(path);
  const pairs = uuidPairs(original, 128);
  const previous = pairs.get(edit.controlId);
  if (
    (edit.label === null && previous === undefined) ||
    (edit.label !== null && previous?.stringValue === edit.label)
  )
    return source;
  if (BigInt(updatedAt) < BigInt(catalog.profiles[index]!.updatedAt))
    throw new Error("profile_timestamp_regression");
  let overrides: LosslessJson;
  if (original?.kind === "array") {
    let selected = -1;
    for (let at = 0; at < original.length!; at += 2)
      if (uuid(original.get(`/${at}`)?.stringValue) === edit.controlId)
        selected = at;
    if (selected >= 0)
      overrides =
        edit.label === null
          ? original.remove(`/${selected + 1}`).remove(`/${selected}`)
          : original.set(`/${selected + 1}`, JSON.stringify(edit.label));
    else {
      // A missing target cannot be a clear operation (the no-op returned above).
      overrides = original
        .set("/-", JSON.stringify(edit.controlId))
        .set("/-", JSON.stringify(edit.label));
    }
  } else {
    const object =
      original?.kind === "object" ? original : LosslessJson.parse("{}");
    const key =
      object.keys.find((key) => uuid(key) === edit.controlId) ?? edit.controlId;
    overrides =
      edit.label === null
        ? object.remove("/" + key)
        : object.set("/" + key, JSON.stringify(edit.label));
  }
  const candidate = source
    .set(path, overrides.text())
    .set(prefix + "/updatedAt", updatedAt);
  if (external) OwnedAuthorityDocument.read(candidate);
  else ConfigurationCatalog.read(candidate);
  readOwnedProfileControls(candidate.get(prefix)!);
  return candidate;
}
