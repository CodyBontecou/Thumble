import { LosslessJson } from "@thumble/contracts/json";

const schema = "com.codybontecou.pocketpad.keypad-configuration";
const rootFields = [
  "schema",
  "version",
  "exportedAt",
  "profiles",
  "activeProfileID",
  "defaultProfileID",
  "keyBindings",
  "outputBindings",
  "profileKeyBindings",
  "profileOutputBindings",
];
const profileFields = [
  "id",
  "name",
  "updatedAt",
  "customization",
  "outputMode",
  "launchTarget",
  "appearanceBank",
  "appearanceResourceVersion",
  "appearanceResources",
  "profileFormatVersion",
];
const forbiddenRoot = [
  "serverid",
  "trustedclients",
  "authtoken",
  "artifactversion",
  "contenthash",
  "catalogrevision",
];
const retiredProfile = [
  "skinReference",
  "skinBaselineCustomization",
  "landscapeSkinBaselineCustomization",
  "portraitSkinBaselineCustomization",
  "landscapeCustomization",
  "portraitCustomization",
  "orientationPreference",
].map(normalized);
function invalid(): never {
  throw new Error("invalid_configuration_catalog");
}
function normalized(text: string): string {
  return text.replace(/[^a-zA-Z0-9]/g, "").toLowerCase();
}
function fields(
  record: LosslessJson,
  known: readonly string[],
  forbidden: readonly string[],
): void {
  if (record.kind !== "object") invalid();
  for (const key of record.keys) {
    const norm = normalized(key);
    if (
      forbidden.includes(norm) ||
      known.some((field) => field !== key && normalized(field) === norm)
    )
      invalid();
  }
}
function uuid(value: string | undefined): string {
  if (
    value === undefined ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
      value,
    )
  )
    invalid();
  return value.toLowerCase();
}
function name(value: string | undefined): string {
  if (
    value === undefined ||
    value.trim().length === 0 ||
    [...value].length > 256
  )
    invalid();
  return value;
}
/** Exact nonnegative Int64 projection, including exponent/fraction spellings. */
export function configurationTimestamp(
  value: LosslessJson | undefined,
): string {
  const token = value?.numberToken;
  if (token === undefined) return invalid();
  const match = /^(-?)(\d+)(?:\.(\d+))?(?:[eE]([+-]?\d+))?$/.exec(token)!;
  let digits = (match[2]! + (match[3] ?? "")).replace(/^0+/, "");
  if (digits === "") return "0";
  if (match[1] === "-") return invalid();
  const exponent = match[4] ?? "0";
  const significantExponent = exponent.replace(/^[+-]/, "").replace(/^0+/, "");
  if (significantExponent.length > 6) return invalid();
  const shift = Number(exponent) - (match[3]?.length ?? 0);
  if (shift >= 0) {
    if (digits.length + shift > 19) return invalid();
    digits += "0".repeat(shift);
  } else {
    if (-shift >= digits.length || !/^0+$/.test(digits.slice(shift)))
      return invalid();
    digits = digits.slice(0, shift);
  }
  if (digits.length > 19 || BigInt(digits) > 9223372036854775807n)
    return invalid();
  return digits;
}
export type ConfigurationProfileSummary = Readonly<{
  id: string;
  name: string;
  updatedAt: string;
}>;

/** V5 envelope/catalog projection only. Layouts, bindings, assets and runtime
 * semantics require their own validators before import or activation. The source
 * remains authoritative; this class must never serialize its typed summaries. */
export class ConfigurationCatalog {
  readonly source: LosslessJson;
  readonly profiles: readonly ConfigurationProfileSummary[];
  readonly activeProfileID: string;
  readonly defaultProfileID: string | null;
  readonly #indices: ReadonlyMap<string, number>;
  private constructor(source: LosslessJson) {
    fields(source, rootFields, forbiddenRoot);
    if (
      source.get("/schema")?.stringValue !== schema ||
      source.get("/version")?.integerValue !== 5
    )
      invalid();
    const exportedAt = source.get("/exportedAt");
    if (exportedAt) configurationTimestamp(exportedAt);
    const records = source.get("/profiles");
    if (
      records?.kind !== "array" ||
      records.length === undefined ||
      records.length < 1 ||
      records.length > 256
    )
      invalid();
    const indices = new Map<string, number>();
    const profiles: ConfigurationProfileSummary[] = [];
    for (let i = 0; i < records.length; i++) {
      const record = records.get(`/${i}`)!;
      fields(record, profileFields, retiredProfile);
      if (record.get("/profileFormatVersion")?.integerValue !== 5) invalid();
      const id = uuid(record.get("/id")?.stringValue);
      if (indices.has(id)) invalid();
      indices.set(id, i);
      profiles.push(
        Object.freeze({
          id,
          name: name(record.get("/name")?.stringValue),
          updatedAt: configurationTimestamp(record.get("/updatedAt")),
        }),
      );
    }
    this.activeProfileID = uuid(source.get("/activeProfileID")?.stringValue);
    const defaultID = source.get("/defaultProfileID");
    this.defaultProfileID =
      defaultID?.kind === "null" ? null : uuid(defaultID?.stringValue);
    if (
      !indices.has(this.activeProfileID) ||
      (this.defaultProfileID !== null && !indices.has(this.defaultProfileID))
    )
      invalid();
    this.source = source;
    this.profiles = Object.freeze(profiles);
    this.#indices = indices;
    Object.freeze(this);
  }
  static read(source: LosslessJson): ConfigurationCatalog {
    return new ConfigurationCatalog(source);
  }
  /** Pure source edit addressed by stable profile ID, never current selection.
   * No persistence, receipt, clock, runtime activation or capability side effect. */
  renameProfile(
    profileID: string,
    newName: string,
    updatedAt: string,
  ): ConfigurationCatalog {
    const id = uuid(profileID);
    const index = this.#indices.get(id);
    if (index === undefined) throw new Error("profile_not_found");
    name(newName);
    // Application clocks pass canonical decimal milliseconds, never JS numbers.
    if (!/^(?:0|[1-9][0-9]{0,18})$/.test(updatedAt)) invalid();
    configurationTimestamp(LosslessJson.parse(updatedAt));
    const previous = this.profiles[index]!;
    if (previous.name === newName) return this;
    if (BigInt(updatedAt) < BigInt(previous.updatedAt))
      throw new Error("profile_timestamp_regression");
    return ConfigurationCatalog.read(
      this.source
        .set(`/profiles/${index}/name`, JSON.stringify(newName))
        .set(`/profiles/${index}/updatedAt`, updatedAt),
    );
  }
}
Object.freeze(ConfigurationCatalog.prototype);
