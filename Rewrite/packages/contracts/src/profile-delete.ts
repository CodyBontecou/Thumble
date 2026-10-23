import { counter, identity, record } from "./receiver.ts";

export type ConfigurationProfileDeleteChange = Readonly<{
  profileId: string;
  activeProfileId: string;
  defaultProfileId: string | null;
}>;
export type ConfigurationDeleteProfileCommand =
  ConfigurationProfileDeleteChange &
    Readonly<{
      command: "configuration-delete-profile";
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
function change(
  value: Record<string, unknown>,
): ConfigurationProfileDeleteChange {
  return Object.freeze({
    profileId: uuid(value.profileId),
    activeProfileId: uuid(value.activeProfileId),
    defaultProfileId:
      value.defaultProfileId === null ? null : uuid(value.defaultProfileId),
  });
}
/** Post-delete selectors are required; no fallback profile is inferred. */
export function decodeConfigurationProfileDeleteChange(
  value: unknown,
): ConfigurationProfileDeleteChange {
  return change(
    fields(value, ["profileId", "activeProfileId", "defaultProfileId"]),
  );
}
export function decodeConfigurationDeleteProfileCommand(
  value: unknown,
): ConfigurationDeleteProfileCommand {
  const v = fields(value, [
    "command",
    "operationId",
    "expectedRevision",
    "profileId",
    "activeProfileId",
    "defaultProfileId",
  ]);
  if (v.command !== "configuration-delete-profile") invalid();
  return Object.freeze({
    command: "configuration-delete-profile",
    operationId: identity(v.operationId),
    expectedRevision: counter(v.expectedRevision),
    ...change(v),
  });
}
