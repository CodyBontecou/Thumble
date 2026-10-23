import { counter, exact, identity, record } from "./receiver.ts";
import { decodePhoneControlsQuery } from "./phone-controls.ts";
export const PRESENTATION_ERRORS = [
  "presentation_busy",
  "presentation_timeout",
  "presentation_unavailable",
  "presentation_reactivation_required",
  "presentation_unsupported_profile",
  "presentation_response_too_large",
  "presentation_stale",
] as const;
export type PresentationError = (typeof PRESENTATION_ERRORS)[number];
export type PhonePresentationBase = Readonly<{
  authorityInstanceId: string;
  expectedConfigurationRevision: string;
  expectedSourceHash: string;
  profileId: string;
  generation: string;
  revision: string;
  viewportWidth: string;
  viewportHeight: string;
  configurationSha256: string;
  colorScheme: "light" | "dark";
}>;
export type PhonePresentationQuery = PhonePresentationBase &
  (
    | Readonly<{ kind: "metadata" }>
    | Readonly<{
        kind: "icon";
        presentationRevision: string;
        presentationSourceHash: string;
        controlId: string;
        iconSHA256: string;
      }>
  );
export type PhonePresentationCommand = PhonePresentationQuery &
  Readonly<{ command: "configuration-phone-presentation" }>;
export type PhonePresentationEvent = PhonePresentationQuery &
  Readonly<{ version: 1; event: "phone-presentation"; eventId: string }>;
export type PhonePresentationResult =
  | Readonly<
      Record<string, string | number> & { kind: "presentation" | "icon" }
    >
  | Readonly<{ kind: "error"; error: PresentationError }>;
const BASE = [
  "authorityInstanceId",
  "expectedConfigurationRevision",
  "expectedSourceHash",
  "profileId",
  "generation",
  "revision",
  "viewportWidth",
  "viewportHeight",
  "configurationSha256",
  "colorScheme",
] as const;
const ICON = [
  "presentationRevision",
  "presentationSourceHash",
  "controlId",
  "iconSHA256",
] as const;
function hash(v: unknown): string {
  if (typeof v !== "string" || !/^[a-f0-9]{64}$/.test(v))
    throw Error("invalid_phone_presentation_hash");
  return v;
}
function utf8Length(v: string): number {
  let bytes = 0;
  for (const c of v) {
    const n = c.codePointAt(0)!;
    if (n >= 0xd800 && n <= 0xdfff)
      throw Error("invalid_phone_presentation_text");
    bytes += n < 128 ? 1 : n < 2048 ? 2 : n < 65536 ? 3 : 4;
  }
  return bytes;
}
function label(v: unknown): void {
  if (typeof v !== "string") throw Error("invalid_phone_presentation_label");
  let bytes = 0;
  for (const c of v) {
    const n = c.codePointAt(0)!;
    if (n >= 0xd800 && n <= 0xdfff)
      throw Error("invalid_phone_presentation_label");
    bytes += n < 128 ? 1 : n < 2048 ? 2 : n < 65536 ? 3 : 4;
  }
  if (bytes > 128) throw Error("invalid_phone_presentation_label");
}
function positive(v: unknown): string {
  const n = counter(v);
  if (n === "0") throw Error("invalid_phone_presentation_revision");
  return n;
}
export function decodePhonePresentationQuery(
  input: unknown,
): PhonePresentationQuery {
  const v = record(input);
  if (v.kind !== "metadata" && v.kind !== "icon")
    throw Error("invalid_phone_presentation_query");
  exact(v, ["kind", ...BASE, ...(v.kind === "icon" ? ICON : [])]);
  decodePhoneControlsQuery(
    Object.fromEntries(BASE.slice(0, 8).map((k) => [k, v[k]])),
  );
  hash(v.configurationSha256);
  if (v.colorScheme !== "light" && v.colorScheme !== "dark")
    throw Error("invalid_phone_presentation_scheme");
  if (v.kind === "icon") {
    positive(v.presentationRevision);
    if (
      BigInt(v.presentationRevision as string) <
      BigInt(v.expectedConfigurationRevision as string)
    )
      throw Error("phone_presentation_pin_mismatch");
    hash(v.presentationSourceHash);
    identity(v.controlId);
    hash(v.iconSHA256);
  }
  return Object.freeze({ ...v }) as PhonePresentationQuery;
}
function queryFields(v: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(
    ["kind", ...BASE, ...(v.kind === "icon" ? ICON : [])].map((k) => [k, v[k]]),
  );
}
export function decodePhonePresentationCommand(
  input: unknown,
): PhonePresentationCommand {
  const v = record(input);
  exact(v, ["command", "kind", ...BASE, ...(v.kind === "icon" ? ICON : [])]);
  if (v.command !== "configuration-phone-presentation")
    throw Error("invalid_phone_presentation_command");
  return Object.freeze({
    ...decodePhonePresentationQuery(queryFields(v)),
    command: "configuration-phone-presentation",
  });
}
export function decodePhonePresentationEvent(
  input: unknown,
  authority: string,
): PhonePresentationEvent {
  const v = record(input);
  exact(v, [
    "version",
    "event",
    "eventId",
    "kind",
    ...BASE,
    ...(v.kind === "icon" ? ICON : []),
  ]);
  if (
    v.version !== 1 ||
    v.event !== "phone-presentation" ||
    v.authorityInstanceId !== authority
  )
    throw Error("invalid_phone_presentation_event");
  return Object.freeze({
    ...decodePhonePresentationQuery(queryFields(v)),
    version: 1,
    event: "phone-presentation",
    eventId: positive(v.eventId),
  });
}
/** Canonical bounded decoding only. Actual bounded PNG decompression is a child-owned port. */
export function presentationIconBytes(value: unknown): Uint8Array {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > 10924 ||
    value.length % 4
  )
    throw Error("invalid_phone_presentation_icon");
  const abc =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  const pad = value.endsWith("==") ? 2 : value.endsWith("=") ? 1 : 0;
  const out = new Uint8Array((value.length / 4) * 3 - pad);
  if (out.length > 8192) throw Error("invalid_phone_presentation_icon");
  let at = 0;
  for (let i = 0; i < value.length; i += 4) {
    const a = abc.indexOf(value[i]!),
      b = abc.indexOf(value[i + 1]!),
      c = i + 2 >= value.length - pad ? 0 : abc.indexOf(value[i + 2]!),
      d = i + 3 >= value.length - pad ? 0 : abc.indexOf(value[i + 3]!);
    if (
      a < 0 ||
      b < 0 ||
      c < 0 ||
      d < 0 ||
      (i + 4 === value.length &&
        ((pad === 2 && (b & 15) !== 0) || (pad === 1 && (c & 3) !== 0)))
    )
      throw Error("invalid_phone_presentation_icon");
    const word = (a << 18) | (b << 12) | (c << 6) | d;
    for (const shift of [16, 8, 0])
      if (at < out.length) out[at++] = (word >>> shift) & 255;
  }
  if (
    out.length < 33 ||
    ![137, 80, 78, 71, 13, 10, 26, 10].every((n, i) => out[i] === n) ||
    new DataView(out.buffer).getUint32(8) !== 13 ||
    String.fromCharCode(...out.slice(12, 16)) !== "IHDR" ||
    new DataView(out.buffer).getUint32(16) !== 32 ||
    new DataView(out.buffer).getUint32(20) !== 32
  )
    throw Error("invalid_phone_presentation_icon");
  return out;
}
export function decodePhonePresentationResult(
  input: unknown,
  query: PhonePresentationQuery,
): PhonePresentationResult {
  const v = record(input);
  if (v.kind === "error") {
    exact(v, ["kind", "error"]);
    if (
      typeof v.error !== "string" ||
      !(PRESENTATION_ERRORS as readonly string[]).includes(v.error)
    )
      throw Error("invalid_phone_presentation_error");
    return Object.freeze({ ...v }) as PhonePresentationResult;
  }
  const limit = query.kind === "metadata" ? 32768 : 16384;
  if (utf8Length(JSON.stringify(v)) > limit - 512)
    throw Error("phone_presentation_response_too_large");
  if (v.kind !== (query.kind === "metadata" ? "presentation" : "icon"))
    throw Error("invalid_phone_presentation_result");
  for (const k of BASE)
    if (v[k] !== query[k]) throw Error("phone_presentation_pin_mismatch");
  const keys: string[] = ["kind", ...BASE];
  if (query.kind === "icon") {
    for (const k of ICON)
      if (v[k] !== query[k]) throw Error("phone_presentation_pin_mismatch");
    keys.push(...ICON, "byteCount", "pngBase64");
    const bytes = presentationIconBytes(v.pngBase64);
    if (v.byteCount !== bytes.length)
      throw Error("invalid_phone_presentation_icon");
  } else {
    keys.push(
      "bank",
      "profileName",
      "presentationRevision",
      "presentationSourceHash",
      "freshness",
      "controlCount",
    );
    if (
      v.bank !== "base" ||
      !["observed", "stale", "not-evaluated"].includes(String(v.freshness)) ||
      typeof v.freshness !== "string" ||
      !Number.isInteger(v.controlCount) ||
      Number(v.controlCount) < 1 ||
      Number(v.controlCount) > 64
    )
      throw Error("invalid_phone_presentation_result");
    label(v.profileName);
    positive(v.presentationRevision);
    if (
      BigInt(v.presentationRevision as string) <
      BigInt(query.expectedConfigurationRevision)
    )
      throw Error("phone_presentation_pin_mismatch");
    hash(v.presentationSourceHash);
    const ids = new Set<string>();
    for (let i = 0; i < Number(v.controlCount); i++) {
      const p = `control${i}`;
      keys.push(p + "Id", p + "Label");
      const id = identity(v[p + "Id"]);
      if (ids.has(id)) throw Error("invalid_phone_presentation_controls");
      ids.add(id);
      label(v[p + "Label"]);
      const icon = [p + "IconSHA256", p + "IconByteCount", p + "IconName"];
      if (icon.some((k) => Object.hasOwn(v, k))) {
        keys.push(...icon);
        hash(v[icon[0]!]);
        label(v[icon[2]!]);
        if (
          !Number.isInteger(v[icon[1]!]) ||
          Number(v[icon[1]!]) < 1 ||
          Number(v[icon[1]!]) > 8192
        )
          throw Error("invalid_phone_presentation_icon");
      }
    }
  }
  exact(v, keys);
  return Object.freeze({ ...v }) as PhonePresentationResult;
}

export type PhonePresentationInstalledPin = Readonly<{
  generation: string;
  revision: string;
  configurationSha256: string;
  expectedConfigurationRevision: string;
  expectedSourceHash: string;
  profileId: string;
}>;
export type PhonePresentationRevision = Readonly<{
  presentationRevision: string;
  presentationSourceHash: string;
  colorScheme: "light" | "dark";
  bank: "base";
}>;
export type PhonePresentationControl = Readonly<{
  id: string;
  label: string;
  iconSHA256?: string;
  iconByteCount?: number;
  iconName?: string;
}>;
export type PhonePresentationNotification =
  | (PhonePresentationInstalledPin &
      PhonePresentationRevision &
      Readonly<{
        kind: "presentation";
        profileName: string;
        freshness: "observed" | "stale" | "not-evaluated";
        controls: readonly PhonePresentationControl[];
      }>)
  | (PhonePresentationInstalledPin &
      PhonePresentationRevision &
      Readonly<{
        kind: "icon";
        controlId: string;
        iconSHA256: string;
        pngBase64: string;
      }>)
  | Readonly<{
      kind: "error";
      error: PresentationError;
      generation: string;
      revision: string;
      configurationSha256: string;
    }>;
const INSTALLED = [
  "generation",
  "revision",
  "configurationSha256",
  "expectedConfigurationRevision",
  "expectedSourceHash",
  "profileId",
] as const;
const PRESENTED = [
  "presentationRevision",
  "presentationSourceHash",
  "colorScheme",
  "bank",
] as const;
function presentationData(input: unknown): Record<string, unknown> {
  const value = record(input);
  if (![Object.prototype, null].includes(Object.getPrototypeOf(value)))
    throw Error("invalid_phone_presentation_notification");
  const result: Record<string, unknown> = Object.create(null);
  for (const key of Reflect.ownKeys(value)) {
    if (typeof key !== "string")
      throw Error("invalid_phone_presentation_notification");
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (!descriptor || !("value" in descriptor) || !descriptor.enumerable)
      throw Error("invalid_phone_presentation_notification");
    result[key] = descriptor.value;
  }
  return result;
}
/** Cosmetic native events only; never grants input, selects a profile, or carries credentials. */
export function decodePhonePresentationNotification(
  input: unknown,
): PhonePresentationNotification {
  const v = presentationData(input);
  positive(v.generation);
  counter(v.revision);
  hash(v.configurationSha256);
  if (v.kind === "error") {
    exact(v, [
      "kind",
      "error",
      "generation",
      "revision",
      "configurationSha256",
    ]);
    if (
      typeof v.error !== "string" ||
      !(PRESENTATION_ERRORS as readonly string[]).includes(v.error)
    )
      throw Error("invalid_phone_presentation_notification");
    return Object.freeze({ ...v }) as PhonePresentationNotification;
  }
  if (v.kind !== "presentation" && v.kind !== "icon")
    throw Error("invalid_phone_presentation_notification");
  positive(v.expectedConfigurationRevision);
  hash(v.expectedSourceHash);
  const pin = decodePhoneControlsQuery({
    authorityInstanceId: "native-presentation",
    expectedConfigurationRevision: v.expectedConfigurationRevision,
    expectedSourceHash: v.expectedSourceHash,
    profileId: v.profileId,
    generation: v.generation,
    revision: v.revision,
    viewportWidth: "874",
    viewportHeight: "393",
  });
  if (pin.profileId !== v.profileId)
    throw Error("invalid_phone_presentation_notification");
  positive(v.presentationRevision);
  hash(v.presentationSourceHash);
  if (
    BigInt(v.presentationRevision as string) <
      BigInt(v.expectedConfigurationRevision as string) ||
    v.bank !== "base" ||
    (v.colorScheme !== "light" && v.colorScheme !== "dark")
  )
    throw Error("invalid_phone_presentation_notification");
  const keys = ["kind", ...INSTALLED, ...PRESENTED];
  if (v.kind === "icon") {
    exact(v, [...keys, "controlId", "iconSHA256", "pngBase64"]);
    identity(v.controlId);
    hash(v.iconSHA256);
    presentationIconBytes(v.pngBase64);
    if (utf8Length(JSON.stringify(v)) > 16384)
      throw Error("phone_presentation_response_too_large");
    return Object.freeze({ ...v }) as PhonePresentationNotification;
  }
  exact(v, [...keys, "profileName", "freshness", "controls"]);
  label(v.profileName);
  if (
    typeof v.freshness !== "string" ||
    !["observed", "stale", "not-evaluated"].includes(v.freshness) ||
    !Array.isArray(v.controls)
  )
    throw Error("invalid_phone_presentation_notification");
  const array = v.controls;
  const length = Object.getOwnPropertyDescriptor(array, "length")?.value;
  if (
    !Number.isInteger(length) ||
    length < 1 ||
    length > 64 ||
    Reflect.ownKeys(array).length !== length + 1
  )
    throw Error("invalid_phone_presentation_notification");
  const controls: PhonePresentationControl[] = [];
  const ids = new Set<string>();
  for (let i = 0; i < length; i++) {
    const descriptor = Object.getOwnPropertyDescriptor(array, String(i));
    if (!descriptor || !("value" in descriptor) || !descriptor.enumerable)
      throw Error("invalid_phone_presentation_notification");
    const c = presentationData(descriptor.value);
    const icon = ["iconSHA256", "iconByteCount", "iconName"];
    const hasIcon = icon.some((k) => Object.hasOwn(c, k));
    exact(c, ["id", "label", ...(hasIcon ? icon : [])]);
    const id = identity(c.id);
    if (ids.has(id)) throw Error("invalid_phone_presentation_notification");
    ids.add(id);
    label(c.label);
    if (hasIcon) {
      hash(c.iconSHA256);
      label(c.iconName);
      if (
        !Number.isInteger(c.iconByteCount) ||
        Number(c.iconByteCount) < 1 ||
        Number(c.iconByteCount) > 8192
      )
        throw Error("invalid_phone_presentation_notification");
    }
    controls.push(Object.freeze({ ...c }) as PhonePresentationControl);
  }
  const result = Object.freeze({
    ...v,
    controls: Object.freeze(controls),
  }) as PhonePresentationNotification;
  if (utf8Length(JSON.stringify(result)) > 32768)
    throw Error("phone_presentation_response_too_large");
  return result;
}
