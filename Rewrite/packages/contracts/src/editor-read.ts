import { counter, record } from "./receiver.ts";
import {
  configurationControlLabel,
  decodeConfigurationSetControlLabelCommand,
  type ConfigurationSetControlLabelCommand,
} from "./control-label.ts";

export const EDITOR_CONTROL_PAGE_SIZE = 8;
export type EditorProfileRead = Readonly<{
  command: "editor-profile";
  expectedRevision: string;
  expectedSourceHash: string;
  profileId: string;
  offset: number;
}>;
export type EditorLabelStatusRead = Readonly<{
  command: "editor-label-status";
  intent: ConfigurationSetControlLabelCommand;
}>;
export type EditorReadCommand = EditorProfileRead | EditorLabelStatusRead;
export type EditorControlSummary = Readonly<{
  id: string;
  generatedLabel: string;
  labelOverride: string | null;
}>;
export type EditorProfilePage = Readonly<{
  version: 1;
  kind: "editor-profile";
  revision: string;
  contentHash: string;
  profileId: string;
  name: string;
  offset: number;
  totalControls: number;
  nextOffset: number | null;
  controls: readonly EditorControlSummary[];
}>;
function invalid(): never {
  throw new Error("invalid_editor_read");
}
function fields(
  value: unknown,
  keys: readonly string[],
): Record<string, unknown> {
  const input = record(value);
  if (
    ![Object.prototype, null].includes(Object.getPrototypeOf(input)) ||
    Reflect.ownKeys(input).length !== keys.length
  )
    invalid();
  const output: Record<string, unknown> = Object.create(null);
  for (const key of keys) {
    const property = Object.getOwnPropertyDescriptor(input, key);
    if (!property || !("value" in property)) invalid();
    output[key] = property.value;
  }
  return output;
}
export function editorProfileId(value: unknown): string {
  if (
    typeof value !== "string" ||
    !/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(value)
  )
    invalid();
  return value.toLowerCase();
}
function hash(value: unknown): string {
  if (typeof value !== "string" || !/^[a-f0-9]{64}$/.test(value)) invalid();
  return value;
}
function offset(value: unknown): number {
  if (
    !Number.isInteger(value) ||
    (value as number) < 0 ||
    (value as number) > 120 ||
    (value as number) % EDITOR_CONTROL_PAGE_SIZE !== 0
  )
    invalid();
  return value as number;
}
export function decodeEditorReadCommand(value: unknown): EditorReadCommand {
  const input = record(value);
  const tag = Object.getOwnPropertyDescriptor(input, "command");
  if (!tag || !("value" in tag)) invalid();
  if (tag.value === "editor-label-status") {
    const v = fields(input, ["command", "intent"]);
    return Object.freeze({
      command: "editor-label-status",
      intent: decodeConfigurationSetControlLabelCommand(v.intent),
    });
  }
  if (tag.value !== "editor-profile") invalid();
  const v = fields(input, [
    "command",
    "expectedRevision",
    "expectedSourceHash",
    "profileId",
    "offset",
  ]);
  return Object.freeze({
    command: "editor-profile",
    expectedRevision: counter(v.expectedRevision),
    expectedSourceHash: hash(v.expectedSourceHash),
    profileId: editorProfileId(v.profileId),
    offset: offset(v.offset),
  });
}
export function decodeEditorProfilePage(value: unknown): EditorProfilePage {
  const v = fields(value, [
    "version",
    "kind",
    "revision",
    "contentHash",
    "profileId",
    "name",
    "offset",
    "totalControls",
    "nextOffset",
    "controls",
  ]);
  if (
    v.version !== 1 ||
    v.kind !== "editor-profile" ||
    typeof v.name !== "string" ||
    [...v.name].length > 256 ||
    !v.name.trim()
  )
    invalid();
  // Validate scalar Unicode using the same label rule in bounded chunks.
  for (const scalar of v.name) configurationControlLabel(scalar);
  const start = offset(v.offset);
  if (
    !Number.isInteger(v.totalControls) ||
    (v.totalControls as number) < 0 ||
    (v.totalControls as number) > 128
  )
    invalid();
  const total = v.totalControls as number;
  if (
    (total === 0 && start !== 0) ||
    (total !== 0 && start >= total) ||
    !Array.isArray(v.controls)
  )
    invalid();
  const count = Math.min(EDITOR_CONTROL_PAGE_SIZE, total - start);
  if (
    v.controls.length !== count ||
    Object.getPrototypeOf(v.controls) !== Array.prototype ||
    Reflect.ownKeys(v.controls).length !== count + 1 ||
    v.nextOffset !== (start + count < total ? start + count : null)
  )
    invalid();
  const controls = Object.freeze(
    Array.from({ length: count }, (_, index) => {
      const entry = Object.getOwnPropertyDescriptor(v.controls, String(index));
      if (!entry || !("value" in entry)) invalid();
      const c = fields(entry.value, ["id", "generatedLabel", "labelOverride"]);
      const generatedLabel = configurationControlLabel(c.generatedLabel);
      if (generatedLabel === null) invalid();
      return Object.freeze({
        id: editorProfileId(c.id),
        generatedLabel,
        labelOverride: configurationControlLabel(c.labelOverride),
      });
    }),
  );
  if (new Set(controls.map((c) => c.id)).size !== controls.length) invalid();
  return Object.freeze({
    version: 1,
    kind: "editor-profile",
    revision: counter(v.revision),
    contentHash: hash(v.contentHash),
    profileId: editorProfileId(v.profileId),
    name: v.name,
    offset: start,
    totalControls: total,
    nextOffset: v.nextOffset as number | null,
    controls,
  });
}
