import { counter, identity, record } from "./receiver.ts";

export type ConfigurationControlLabelChange = Readonly<{
  profileId: string;
  controlId: string;
  /** null removes the user override; an empty string is an explicit blank. */
  label: string | null;
}>;
export type ConfigurationSetControlLabelCommand =
  ConfigurationControlLabelChange &
    Readonly<{
      command: "configuration-set-control-label";
      operationId: string;
      expectedRevision: string;
    }>;
function invalid(): never {
  throw new Error("invalid_configuration_request");
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
  const result: Record<string, unknown> = Object.create(null);
  for (const key of keys) {
    const property = Object.getOwnPropertyDescriptor(input, key);
    if (!property || !("value" in property)) invalid();
    result[key] = property.value;
  }
  return result;
}
function uuid(value: unknown): string {
  if (
    typeof value !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
      value,
    )
  )
    invalid();
  return value.toLowerCase();
}
/** Presentation wire parity: valid scalar Unicode, at most 128 UTF-8 bytes. */
export function configurationControlLabel(value: unknown): string | null {
  if (value === null) return null;
  if (typeof value !== "string" || value.length > 128) invalid();
  let bytes = 0;
  for (const character of value) {
    const scalar = character.codePointAt(0)!;
    if (scalar >= 0xd800 && scalar <= 0xdfff) invalid();
    bytes += scalar < 128 ? 1 : scalar < 2048 ? 2 : scalar < 65536 ? 3 : 4;
    if (bytes > 128) invalid();
  }
  return value;
}
export function decodeConfigurationControlLabelChange(
  value: unknown,
): ConfigurationControlLabelChange {
  const v = fields(value, ["profileId", "controlId", "label"]);
  return Object.freeze({
    profileId: uuid(v.profileId),
    controlId: uuid(v.controlId),
    label: configurationControlLabel(v.label),
  });
}
export function decodeConfigurationSetControlLabelCommand(
  value: unknown,
): ConfigurationSetControlLabelCommand {
  const v = fields(value, [
    "command",
    "operationId",
    "expectedRevision",
    "profileId",
    "controlId",
    "label",
  ]);
  if (v.command !== "configuration-set-control-label") invalid();
  return Object.freeze({
    command: "configuration-set-control-label",
    operationId: identity(v.operationId),
    expectedRevision: counter(v.expectedRevision),
    profileId: uuid(v.profileId),
    controlId: uuid(v.controlId),
    label: configurationControlLabel(v.label),
  });
}
