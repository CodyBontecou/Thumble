import type { LosslessJson } from "@thumble/contracts/json";
import {
  EDITOR_CONTROL_PAGE_SIZE,
  decodeEditorReadCommand,
  decodeEditorProfilePage,
  type EditorProfilePage,
  type EditorProfileRead,
} from "@thumble/contracts/editor-read";
import { configurationControlLabel } from "@thumble/contracts/control-label";
import { ConfigurationCatalog } from "./configuration-catalog.ts";
import { OwnedAuthorityDocument } from "./owned-authority.ts";
import { readOwnedProfileControls } from "./owned-profile.ts";
import { uuidPairs } from "./owned-json.ts";

/** Saved-source summary only. No runtime pin, assets, output bindings or write authority. */
export function projectOwnedEditorProfilePage(
  source: LosslessJson,
  request: EditorProfileRead,
): EditorProfilePage {
  const query = decodeEditorReadCommand(request);
  if (query.command !== "editor-profile")
    throw new Error("invalid_editor_read");
  const authority = OwnedAuthorityDocument.isAuthority(source)
    ? OwnedAuthorityDocument.read(source)
    : undefined;
  const body = authority ? source.get("/document")! : source;
  const catalog = authority?.catalog ?? ConfigurationCatalog.read(body);
  const index = catalog.profiles.findIndex((p) => p.id === query.profileId);
  if (index < 0) throw new Error("profile_not_found");
  const profile = body.get(`/profiles/${index}`)!;
  const labels = uuidPairs(profile.get("/customization/labelOverrides"));
  const controls = readOwnedProfileControls(profile).map((control) => {
    const raw = control.source.get("/label");
    const override = labels.get(control.id);
    const generatedLabel = configurationControlLabel(
      raw === undefined ? "" : raw.stringValue,
    );
    if (generatedLabel === null)
      throw new Error("configuration_editor_profile_unsupported");
    return Object.freeze({
      id: control.id,
      generatedLabel,
      labelOverride:
        override === undefined
          ? null
          : configurationControlLabel(override.stringValue),
    });
  });
  const next =
    query.offset +
    Math.min(EDITOR_CONTROL_PAGE_SIZE, controls.length - query.offset);
  return decodeEditorProfilePage({
    version: 1,
    kind: "editor-profile",
    revision: query.expectedRevision,
    contentHash: query.expectedSourceHash,
    profileId: query.profileId,
    name: catalog.profiles[index]!.name,
    offset: query.offset,
    totalControls: controls.length,
    nextOffset: next < controls.length ? next : null,
    controls: controls.slice(
      query.offset,
      query.offset + EDITOR_CONTROL_PAGE_SIZE,
    ),
  });
}
