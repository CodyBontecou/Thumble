import { counter, identity, record } from "./receiver.ts";

export const CONFIGURATION_PAGE_SIZE = 16;
export type ConfigurationCommand =
  | Readonly<{
      command: "configuration-list";
      expectedRevision: string | null;
      offset: number;
    }>
  | Readonly<{
      command: "configuration-rename-profile";
      operationId: string;
      expectedRevision: string;
      profileId: string;
      name: string;
    }>;
export type ConfigurationReceipt = Readonly<{
  version: 1;
  operationId: string;
  resultingRevision: string;
  contentHash: string;
  affectedEntities: readonly string[];
}>;
export type ConfigurationReply =
  | Readonly<{
      version: 1;
      kind: "catalog";
      revision: string;
      contentHash: string | null;
      profiles: readonly Readonly<{
        id: string;
        name: string;
        updatedAt: string;
      }>[];
      activeProfileId: string | null;
      defaultProfileId: string | null;
      nextOffset: number | null;
    }>
  | Readonly<{ version: 1; kind: "conflict"; currentRevision: string }>
  | Readonly<{
      version: 1;
      kind: "committed";
      receipt: ConfigurationReceipt;
      replayed: boolean;
    }>;
function invalid(): never {
  throw new Error("invalid_configuration_request");
}
/** Copy only own data properties; never execute accessors at a trust boundary. */
function object(
  value: unknown,
  fields: readonly string[],
): Record<string, unknown> {
  const input = record(value);
  if (
    ![Object.prototype, null].includes(Object.getPrototypeOf(input)) ||
    Reflect.ownKeys(input).length !== fields.length
  )
    invalid();
  const result: Record<string, unknown> = Object.create(null);
  for (const key of fields) {
    const descriptor = Object.getOwnPropertyDescriptor(input, key);
    if (!descriptor || !("value" in descriptor)) invalid();
    result[key] = descriptor.value;
  }
  return result;
}
export function configurationProfileId(value: unknown): string {
  if (
    typeof value !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
      value,
    )
  )
    invalid();
  return value.toLowerCase();
}
export function configurationProfileName(value: unknown): string {
  if (
    typeof value !== "string" ||
    value.trim().length === 0 ||
    [...value].length > 256
  )
    invalid();
  // JSON strings may contain lone surrogates; the lossless document cannot.
  for (let i = 0; i < value.length; i++) {
    const unit = value.charCodeAt(i);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      const next = value.charCodeAt(++i);
      if (!(next >= 0xdc00 && next <= 0xdfff)) invalid();
    } else if (unit >= 0xdc00 && unit <= 0xdfff) invalid();
  }
  return value;
}
function offset(value: unknown): number {
  if (
    typeof value !== "number" ||
    !Number.isInteger(value) ||
    value < 0 ||
    value > 255
  )
    invalid();
  return value;
}
function hash(value: unknown): string {
  if (typeof value !== "string" || !/^[0-9a-f]{64}$/.test(value)) invalid();
  return value;
}
export function decodeConfigurationCommand(
  value: unknown,
): ConfigurationCommand {
  const kind = Object.getOwnPropertyDescriptor(record(value), "command")?.value;
  if (kind === "configuration-list") {
    const v = object(value, ["command", "expectedRevision", "offset"]);
    if (v.offset !== 0 && v.expectedRevision === null) invalid();
    return Object.freeze({
      command: kind,
      expectedRevision:
        v.expectedRevision === null ? null : counter(v.expectedRevision),
      offset: offset(v.offset),
    });
  }
  if (kind === "configuration-rename-profile") {
    const v = object(value, [
      "command",
      "operationId",
      "expectedRevision",
      "profileId",
      "name",
    ]);
    return Object.freeze({
      command: kind,
      operationId: identity(v.operationId),
      expectedRevision: counter(v.expectedRevision),
      profileId: configurationProfileId(v.profileId),
      name: configurationProfileName(v.name),
    });
  }
  return invalid();
}
export function decodeConfigurationReply(
  value: unknown,
  command: ConfigurationCommand,
): ConfigurationReply {
  const kind = Object.getOwnPropertyDescriptor(record(value), "kind")?.value;
  if (kind === "conflict") {
    const v = object(value, ["version", "kind", "currentRevision"]);
    if (
      v.version !== 1 ||
      command.expectedRevision === null ||
      v.currentRevision === command.expectedRevision
    )
      invalid();
    return Object.freeze({
      version: 1,
      kind,
      currentRevision: counter(v.currentRevision),
    });
  }
  if (
    kind === "committed" &&
    command.command === "configuration-rename-profile"
  ) {
    const v = object(value, ["version", "kind", "receipt", "replayed"]);
    const r = object(v.receipt, [
      "version",
      "operationId",
      "resultingRevision",
      "contentHash",
      "affectedEntities",
    ]);
    const affected = r.affectedEntities;
    if (
      v.version !== 1 ||
      r.version !== 1 ||
      r.operationId !== command.operationId ||
      typeof v.replayed !== "boolean" ||
      r.resultingRevision !==
        (BigInt(command.expectedRevision) + 1n).toString() ||
      !Array.isArray(affected) ||
      affected.length !== 1 ||
      Object.getOwnPropertyDescriptor(affected, "0")?.value !==
        command.profileId
    )
      invalid();
    return Object.freeze({
      version: 1,
      kind,
      replayed: v.replayed,
      receipt: Object.freeze({
        version: 1,
        operationId: command.operationId,
        resultingRevision: counter(r.resultingRevision),
        contentHash: hash(r.contentHash),
        affectedEntities: Object.freeze([command.profileId]),
      }),
    });
  }
  if (kind === "catalog" && command.command === "configuration-list") {
    const v = object(value, [
      "version",
      "kind",
      "revision",
      "contentHash",
      "profiles",
      "activeProfileId",
      "defaultProfileId",
      "nextOffset",
    ]);
    const revision = counter(v.revision);
    if (
      v.version !== 1 ||
      (command.expectedRevision !== null &&
        command.expectedRevision !== revision) ||
      !Array.isArray(v.profiles) ||
      v.profiles.length > CONFIGURATION_PAGE_SIZE
    )
      invalid();
    const profiles: Array<
      Readonly<{ id: string; name: string; updatedAt: string }>
    > = [];
    for (let i = 0; i < v.profiles.length; i++) {
      const entry = Object.getOwnPropertyDescriptor(v.profiles, String(i));
      if (!entry || !("value" in entry)) invalid();
      const p = object(entry.value, ["id", "name", "updatedAt"]);
      const updatedAt = counter(p.updatedAt);
      if (BigInt(updatedAt) > 9223372036854775807n) invalid();
      profiles.push(
        Object.freeze({
          id: configurationProfileId(p.id),
          name: configurationProfileName(p.name),
          updatedAt,
        }),
      );
    }
    if (new Set(profiles.map((p) => p.id)).size !== profiles.length) invalid();
    const nextOffset = v.nextOffset === null ? null : offset(v.nextOffset);
    if (
      nextOffset !== null &&
      (profiles.length !== CONFIGURATION_PAGE_SIZE ||
        nextOffset !== command.offset + profiles.length)
    )
      invalid();
    const activeProfileId =
      v.activeProfileId === null
        ? null
        : configurationProfileId(v.activeProfileId);
    const defaultProfileId =
      v.defaultProfileId === null
        ? null
        : configurationProfileId(v.defaultProfileId);
    if (revision === "0") {
      if (
        v.contentHash !== null ||
        profiles.length !== 0 ||
        activeProfileId !== null ||
        defaultProfileId !== null ||
        nextOffset !== null ||
        command.offset !== 0
      )
        invalid();
    } else if (activeProfileId === null || profiles.length === 0) invalid();
    return Object.freeze({
      version: 1,
      kind,
      revision,
      contentHash: revision === "0" ? null : hash(v.contentHash),
      profiles: Object.freeze(profiles),
      activeProfileId,
      defaultProfileId,
      nextOffset,
    });
  }
  return invalid();
}
