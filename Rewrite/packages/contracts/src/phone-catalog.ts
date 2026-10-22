import {
  decodeConfigurationCommand,
  decodeConfigurationReply,
  type ConfigurationCommand,
} from "./configuration.ts";
import { exact, record } from "./receiver.ts";

export type PhoneCatalogCommand = Extract<
  ConfigurationCommand,
  { command: "configuration-list" }
>;
export type PhoneCatalogError =
  | "phone_catalog_busy"
  | "phone_catalog_timeout"
  | "phone_catalog_unavailable";
export type PhoneCatalogEvent = Readonly<{
  version: 1;
  event: "phone-catalog";
  eventId: string;
  authorityInstanceId: string;
  expectedRevision: string | null;
  offset: number;
}>;
export type PhoneCatalogPage = Readonly<
  Record<string, string | number | null> & {
    kind: "catalog";
    profileCount: number;
    nextOffset: number | null;
  }
>;
export type PhoneCatalogResult =
  | PhoneCatalogPage
  | Readonly<{ kind: "conflict"; currentRevision: string }>;
export function decodePhoneCatalogEvent(
  value: unknown,
  authority: string,
): PhoneCatalogEvent {
  const v = record(value);
  exact(v, [
    "version",
    "event",
    "eventId",
    "authorityInstanceId",
    "expectedRevision",
    "offset",
  ]);
  if (
    v.version !== 1 ||
    v.event !== "phone-catalog" ||
    v.authorityInstanceId !== authority ||
    typeof v.eventId !== "string" ||
    !/^[1-9][0-9]{0,19}$/.test(v.eventId) ||
    BigInt(v.eventId) > 18446744073709551615n
  )
    throw new Error("invalid_phone_catalog_event");
  const command = phoneCatalogCommand({
    expectedRevision: v.expectedRevision,
    offset: v.offset,
  });
  return Object.freeze({
    version: 1,
    event: "phone-catalog",
    eventId: v.eventId,
    authorityInstanceId: authority,
    expectedRevision: command.expectedRevision,
    offset: command.offset,
  });
}
export function phoneCatalogCommand(value: {
  expectedRevision: unknown;
  offset: unknown;
}): PhoneCatalogCommand {
  const command = decodeConfigurationCommand({
    command: "configuration-list",
    expectedRevision: value.expectedRevision,
    offset: value.offset,
  });
  if (command.command !== "configuration-list")
    throw new Error("invalid_phone_catalog_command");
  return command;
}
/** Project validated metadata only. Never forward source documents, paths, or credentials. */
export function projectPhoneCatalog(
  value: unknown,
  command: PhoneCatalogCommand,
): PhoneCatalogResult {
  const reply = decodeConfigurationReply(value, command);
  if (reply.kind === "conflict")
    return Object.freeze({
      kind: "conflict",
      currentRevision: reply.currentRevision,
    });
  if (reply.kind !== "catalog") throw new Error("invalid_phone_catalog_result");
  const result: Record<string, string | number | null> & {
    kind: "catalog";
    profileCount: number;
    nextOffset: number | null;
  } = {
    kind: "catalog",
    revision: reply.revision,
    contentHash: reply.contentHash,
    activeProfileId: reply.activeProfileId,
    defaultProfileId: reply.defaultProfileId,
    nextOffset: reply.nextOffset,
    profileCount: reply.profiles.length,
  };
  reply.profiles.forEach((profile, i) => {
    result[`profile${i}Id`] = profile.id;
    result[`profile${i}Name`] = profile.name;
    result[`profile${i}UpdatedAt`] = profile.updatedAt;
  });
  return Object.freeze(result);
}

export type PhoneCatalogNotification =
  | Readonly<{ kind: "error"; error: PhoneCatalogError }>
  | PhoneCatalogPage;
/** Strict first-page notification boundary used by the phone's native view. */
export function decodePhoneCatalogNotification(
  value: unknown,
): PhoneCatalogNotification {
  const v = record(value);
  if (v.kind === "error") {
    exact(v, ["kind", "error"]);
    if (
      v.error !== "phone_catalog_busy" &&
      v.error !== "phone_catalog_timeout" &&
      v.error !== "phone_catalog_unavailable"
    )
      throw new Error("invalid_phone_catalog_notification");
    return Object.freeze({ kind: "error", error: v.error });
  }
  if (
    v.kind !== "catalog" ||
    !Number.isInteger(v.profileCount) ||
    typeof v.profileCount !== "number" ||
    v.profileCount < 0 ||
    v.profileCount > 16
  )
    throw new Error("invalid_phone_catalog_notification");
  const keys = [
    "kind",
    "revision",
    "contentHash",
    "activeProfileId",
    "defaultProfileId",
    "nextOffset",
    "profileCount",
  ];
  const profiles = Array.from({ length: v.profileCount }, (_, i) => {
    keys.push(`profile${i}Id`, `profile${i}Name`, `profile${i}UpdatedAt`);
    return {
      id: v[`profile${i}Id`],
      name: v[`profile${i}Name`],
      updatedAt: v[`profile${i}UpdatedAt`],
    };
  });
  exact(v, keys);
  const result = projectPhoneCatalog(
    {
      version: 1,
      kind: "catalog",
      revision: v.revision,
      contentHash: v.contentHash,
      activeProfileId: v.activeProfileId,
      defaultProfileId: v.defaultProfileId,
      nextOffset: v.nextOffset,
      profiles,
    },
    { command: "configuration-list", expectedRevision: null, offset: 0 },
  );
  if (result.kind !== "catalog")
    throw new Error("invalid_phone_catalog_notification");
  return result;
}
