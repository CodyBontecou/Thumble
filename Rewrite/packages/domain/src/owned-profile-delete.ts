import { LosslessJson } from "@thumble/contracts/json";
import {
  decodeConfigurationProfileDeleteChange,
  type ConfigurationProfileDeleteChange,
} from "@thumble/contracts/profile-delete";
import { ConfigurationCatalog } from "./configuration-catalog.ts";
import { OwnedAuthorityDocument } from "./owned-authority.ts";
import { readOwnedProfileControls } from "./owned-profile.ts";
import { validateOwnedBindingMaps } from "./owned-bindings.ts";
import { entries, rows, uuid } from "./owned-json.ts";

export type OwnedProfileDeleteChange = ConfigurationProfileDeleteChange;
const segment = (key: string) =>
  key.replaceAll("~", "~0").replaceAll("/", "~1");
function validateBindings(
  body: LosslessJson,
  catalog: ConfigurationCatalog,
): void {
  const owners = new Map(
    catalog.profiles.map(
      (profile, index) =>
        [
          profile.id,
          new Set(
            readOwnedProfileControls(body.get(`/profiles/${index}`)!).map(
              (control) => control.id,
            ),
          ),
        ] as const,
    ),
  );
  validateOwnedBindingMaps(body, owners, catalog.activeProfileID);
}
/** Pure saved-source deletion. Runtime pins, input epochs and asset bytes are
 * owned elsewhere; this function performs no release, activation or asset GC. */
export function deleteOwnedProfile(
  source: LosslessJson,
  change: OwnedProfileDeleteChange,
): LosslessJson {
  const edit = decodeConfigurationProfileDeleteChange(change);
  const external = OwnedAuthorityDocument.isAuthority(source);
  const authority = external ? OwnedAuthorityDocument.read(source) : undefined;
  const body = external ? source.get("/document")! : source;
  const catalog = authority?.catalog ?? ConfigurationCatalog.read(body);
  const index = catalog.profiles.findIndex(
    (profile) => profile.id === edit.profileId,
  );
  if (index < 0) throw new Error("profile_not_found");
  if (catalog.profiles.length === 1)
    throw new Error("configuration_last_profile");
  if (
    edit.activeProfileId === edit.profileId ||
    edit.defaultProfileId === edit.profileId
  )
    throw new Error("invalid_profile_selection");
  validateBindings(body, catalog);
  // Selection resolves and validates explicit replacement IDs before removal,
  // preserving retained empty-override and initial-output fallback semantics.
  let candidate = catalog
    .selectProfiles(edit.activeProfileId, edit.defaultProfileId)
    .source.remove(`/profiles/${index}`);
  for (const name of ["profileKeyBindings", "profileOutputBindings"]) {
    const map = candidate.get("/" + name);
    if (!map) continue;
    for (const [key] of entries(map, 512))
      if (uuid(key) === edit.profileId)
        candidate = candidate.remove("/" + name + "/" + segment(key));
  }
  const resultCatalog = ConfigurationCatalog.read(candidate);
  validateBindings(candidate, resultCatalog);
  if (!external) return candidate;
  const resources = rows(source.get("/resources"), 8192).flatMap((value) => {
    const path = value.get("/path")!.stringValue!;
    const match = /^\/profiles\/(0|[1-9][0-9]*)\//.exec(path)!;
    const oldIndex = Number(match[1]);
    if (oldIndex === index) return [];
    const newPath =
      oldIndex > index
        ? `/profiles/${oldIndex - 1}/` + path.slice(match[0].length)
        : path;
    return [
      {
        path: newPath,
        value:
          newPath === path
            ? value
            : value.set("/path", JSON.stringify(newPath)),
      },
    ];
  });
  resources.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  const result = source
    .set("/document", candidate.text())
    .set(
      "/resources",
      `[${resources.map((resource) => resource.value.text()).join(",")}]`,
    );
  OwnedAuthorityDocument.read(result);
  return result;
}
