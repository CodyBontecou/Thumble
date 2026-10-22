import { LosslessJson } from "@thumble/contracts/json";
import { ConfigurationCatalog } from "./configuration-catalog.ts";
import { OwnedConfigurationDocument } from "./owned-configuration.ts";
import { OWNED_SURFACE_FIELDS, OWNED_CONTROL_FIELDS } from "./owned-profile.ts";
import {
  decodeResourceBase64,
  encodeResourceBase64,
  type ResourceDigest,
} from "./owned-resources.ts";
import { entries, object, only, rows, unsigned } from "./owned-json.ts";

export const OWNED_AUTHORITY_SCHEMA =
  "com.codybontecou.thumble.owned-authority";
const MAX_BYTES = 8 * 1024 * 1024;
export type AuthorityResource = Readonly<{
  path: string;
  sha256: string;
  byteCount: number;
}>;
export type OwnedAuthorityPreparation = Readonly<{
  document: OwnedAuthorityDocument;
  assets: () => readonly Uint8Array[];
}>;
function invalid(): never {
  throw new Error("invalid_owned_authority");
}
const segment = (key: string) =>
  key.replaceAll("~", "~0").replaceAll("/", "~1");
function hash(value: string | undefined): string {
  if (value === undefined || !/^[0-9a-f]{64}$/.test(value)) invalid();
  return value;
}
/** Inventory only actual resource-pool and appearance binary slots. Unknown
 * metadata named data remains opaque; original resourceSHA256 aliases survive. */
function slots(document: LosslessJson): ReadonlyMap<string, LosslessJson> {
  const result = new Map<string, LosslessJson>();
  function add(path: string, value: LosslessJson, pooled = false) {
    if (result.size >= 8192 || path.length > 4096) invalid();
    if (
      !pooled &&
      value.kind === "object" &&
      value.keys.length === 1 &&
      value.get("/resourceSHA256")
    )
      return;
    result.set(path, value);
  }
  function walk(node: LosslessJson, path: string, assetEntry = false) {
    if (node.kind === "object") {
      if (assetEntry) {
        const data = node.get("/data");
        if (data && data.kind !== "null") add(path + "/data", data);
      }
      if (node.get("/kind")?.stringValue === "image") {
        const data = node.get("/image/data");
        if (data && data.kind !== "null") add(path + "/image/data", data);
      }
      for (const [key, value] of entries(node, 131072))
        walk(value, path + "/" + segment(key));
    } else if (node.kind === "array")
      rows(node, 131072).forEach((item, i) => walk(item, path + "/" + i));
  }
  rows(document.get("/profiles"), 256).forEach((profile, index) => {
    const prefix = `/profiles/${index}`;
    const resources = profile.get("/appearanceResources");
    if (resources)
      for (const [key, value] of entries(resources, 131072))
        add(prefix + "/appearanceResources/" + hash(key), value, true);
    const visitFields = (
      node: LosslessJson,
      path: string,
      fields: readonly string[],
    ) => {
      for (const key of fields) {
        const value = node.get("/" + key);
        if (value) walk(value, path + "/" + key);
      }
    };
    const customization = profile.get("/customization");
    if (customization) {
      const base = prefix + "/customization";
      visitFields(customization, base, OWNED_SURFACE_FIELDS);
      for (const key of ["artworkLayers", "styleLibrary/styles"]) {
        const value = customization.get("/" + key);
        if (value) walk(value, base + "/" + key);
      }
      const assets = customization.get("/assetLibrary/assets");
      if (assets?.kind === "array")
        rows(assets).forEach((value, i) =>
          walk(value, base + "/assetLibrary/assets/" + i, true),
        );
      for (const key of ["elements", "customButtons"]) {
        const values = customization.get("/" + key);
        if (values?.kind === "array")
          rows(values).forEach((value, i) => {
            const layout = value.get("/layout");
            if (layout)
              visitFields(
                layout,
                base + "/" + key + "/" + i + "/layout",
                OWNED_CONTROL_FIELDS,
              );
          });
      }
      const overrides = customization.get("/buttonCustomizations");
      if (overrides?.kind === "object")
        for (const [key, value] of entries(overrides))
          visitFields(
            value,
            base + "/buttonCustomizations/" + segment(key),
            OWNED_CONTROL_FIELDS,
          );
      else if (overrides?.kind === "array")
        rows(overrides).forEach((value, i) => {
          if (i % 2 === 1)
            visitFields(
              value,
              base + "/buttonCustomizations/" + i,
              OWNED_CONTROL_FIELDS,
            );
        });
      const top = customization.get("/topBarActivationRegion");
      if (top)
        visitFields(
          top,
          base + "/topBarActivationRegion",
          OWNED_CONTROL_FIELDS,
        );
      const bars = customization.get("/controlBarItemCustomizations");
      if (bars?.kind === "array")
        rows(bars).forEach((value, i) => {
          const appearance = value.get("/appearance");
          if (appearance)
            visitFields(
              appearance,
              base + "/controlBarItemCustomizations/" + i + "/appearance",
              OWNED_CONTROL_FIELDS,
            );
        });
    }
    const variants = profile.get("/appearanceBank/variants");
    if (variants?.kind === "array")
      rows(variants, 8).forEach((variant, i) => {
        const appearance = variant.get("/appearance");
        if (appearance) {
          const base = prefix + "/appearanceBank/variants/" + i + "/appearance";
          for (const [key, value] of entries(appearance)) {
            if (key === "assetLibrary") {
              const assets = value.get("/assets");
              if (assets?.kind === "array")
                rows(assets).forEach((asset, index) =>
                  walk(asset, base + "/assetLibrary/assets/" + index, true),
                );
            } else walk(value, base + "/" + key);
          }
        }
      });
  });
  return result;
}
function descriptor(
  value: LosslessJson,
): Readonly<{ sha256: string; byteCount: number }> {
  only(object(value), ["assetSHA256", "byteCount"]);
  return Object.freeze({
    sha256: hash(value.get("/assetSHA256")?.stringValue),
    byteCount: unsigned(value.get("/byteCount"), MAX_BYTES),
  });
}
/** Private stored representation. It is never accepted as an interchange file
 * and never grants runtime/render validity from its catalog projection. */
export class OwnedAuthorityDocument {
  readonly source: LosslessJson;
  readonly catalog: ConfigurationCatalog;
  readonly resources: readonly AuthorityResource[];
  private readonly body: LosslessJson;
  private constructor(source: LosslessJson) {
    only(source, ["schema", "version", "document", "resources"]);
    if (
      source.get("/schema")?.stringValue !== OWNED_AUTHORITY_SCHEMA ||
      source.get("/version")?.integerValue !== 1
    )
      invalid();
    this.source = source;
    this.body = object(source.get("/document"));
    this.catalog = ConfigurationCatalog.read(this.body);
    const found = slots(this.body),
      resources: AuthorityResource[] = [];
    const unique = new Map<string, number>();
    let previous = "",
      total = 0,
      projectedBytes = this.body.byteLength;
    for (const row of rows(source.get("/resources"), 8192)) {
      only(row, ["path", "sha256", "byteCount"]);
      const path = row.get("/path")?.stringValue;
      if (!path || path.length > 4096 || path <= previous) invalid();
      previous = path;
      const sha256 = hash(row.get("/sha256")?.stringValue),
        byteCount = unsigned(row.get("/byteCount"), MAX_BYTES);
      const slot = found.get(path);
      if (!slot) invalid();
      const value = descriptor(slot);
      projectedBytes += 4 * Math.ceil(byteCount / 3) + 2 - slot.byteLength;
      const poolKey = /\/appearanceResources\/([0-9a-f]{64})$/.exec(path)?.[1];
      if (poolKey !== undefined && poolKey !== sha256) invalid();
      if (value.sha256 !== sha256 || value.byteCount !== byteCount) invalid();
      const prior = unique.get(sha256);
      if (prior !== undefined && prior !== byteCount) invalid();
      if (prior === undefined) {
        unique.set(sha256, byteCount);
        total += byteCount;
      }
      if (unique.size > 256 || total > MAX_BYTES) invalid();
      resources.push(Object.freeze({ path, sha256, byteCount }));
    }
    if (found.size !== resources.length || projectedBytes > MAX_BYTES)
      invalid();
    this.resources = Object.freeze(resources);
    Object.freeze(this);
  }
  static isAuthority(source: LosslessJson): boolean {
    return source.get("/schema")?.stringValue === OWNED_AUTHORITY_SCHEMA;
  }
  static read(source: LosslessJson): OwnedAuthorityDocument {
    return new OwnedAuthorityDocument(source);
  }
  static prepare(
    source: LosslessJson,
    digest: ResourceDigest,
  ): OwnedAuthorityPreparation {
    OwnedConfigurationDocument.read(source, digest);
    const edits = new Map<string, LosslessJson>(),
      resources: AuthorityResource[] = [],
      pool = new Map<string, Uint8Array>();
    let total = 0;
    for (const [path, value] of [...slots(source)].sort(([a], [b]) =>
      a < b ? -1 : a > b ? 1 : 0,
    )) {
      // Retained pooled aliases remain references; the pool's bytes are extracted once.
      if (
        value.kind === "object" &&
        value.keys.length === 1 &&
        value.get("/resourceSHA256")
      )
        continue;
      const encoded = value.stringValue;
      if (encoded === undefined) invalid();
      const bytes = decodeResourceBase64(encoded),
        sha256 = hash(digest(bytes.slice()));
      const previous = pool.get(sha256);
      if (
        previous &&
        (previous.length !== bytes.length ||
          previous.some((v, i) => v !== bytes[i]))
      )
        invalid();
      if (!previous) {
        pool.set(sha256, bytes);
        total += bytes.length;
      }
      if (pool.size > 256 || total > MAX_BYTES) invalid();
      resources.push(Object.freeze({ path, sha256, byteCount: bytes.length }));
      edits.set(
        path,
        LosslessJson.parse(
          JSON.stringify({ assetSHA256: sha256, byteCount: bytes.length }),
        ),
      );
    }
    const body = source.replaceValues(edits);
    const envelope = LosslessJson.parse(
      `{"schema":${JSON.stringify(OWNED_AUTHORITY_SCHEMA)},"version":1,"document":${body.text()},"resources":${JSON.stringify(resources)}}`,
    );
    const document = OwnedAuthorityDocument.read(envelope);
    return Object.freeze({
      document,
      assets: () =>
        Object.freeze([...pool.values()].map((bytes) => bytes.slice())),
    });
  }
  materialize(
    read: (sha256: string) => Uint8Array,
    digest: ResourceDigest,
  ): OwnedConfigurationDocument {
    const cache = new Map<string, LosslessJson>(),
      edits = new Map<string, LosslessJson>();
    for (const resource of this.resources) {
      let replacement = cache.get(resource.sha256);
      if (replacement === undefined) {
        const raw = read(resource.sha256);
        if (!(raw instanceof Uint8Array) || raw.length !== resource.byteCount)
          invalid();
        const bytes = new Uint8Array(raw);
        if (hash(digest(bytes.slice())) !== resource.sha256) invalid();
        replacement = LosslessJson.parse(
          JSON.stringify(encodeResourceBase64(bytes)),
        );
        cache.set(resource.sha256, replacement);
      }
      edits.set(resource.path, replacement);
    }
    return OwnedConfigurationDocument.read(
      this.body.replaceValues(edits),
      digest,
    );
  }
  duplicateProfile(
    profileID: string,
    newProfileID: string,
    name: string,
    updatedAt: string,
    select: boolean,
  ): OwnedAuthorityDocument {
    const id = profileID.toLowerCase(),
      index = this.catalog.profiles.findIndex((profile) => profile.id === id);
    if (index < 0) throw new Error("profile_not_found");
    const candidate = this.catalog.duplicateProfile(
        profileID,
        newProfileID,
        name,
        updatedAt,
        select,
      ),
      prefix = `/profiles/${index}/`,
      target = `/profiles/${this.catalog.profiles.length}/`;
    const records = rows(this.source.get("/resources"), 8192).map((value) => ({
      path: value.get("/path")!.stringValue!,
      value,
    }));
    for (const record of [...records])
      if (record.path.startsWith(prefix)) {
        const path = target + record.path.slice(prefix.length);
        records.push({
          path,
          value: record.value.set("/path", JSON.stringify(path)),
        });
      }
    records.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
    // Existing descriptors retain their raw numeric/string source. Aliases share
    // immutable hashes; the reader rechecks slot coverage and materialized size.
    return OwnedAuthorityDocument.read(
      this.source
        .set("/document", candidate.source.text())
        .set(
          "/resources",
          `[${records.map((record) => record.value.text()).join(",")}]`,
        ),
    );
  }
  selectProfiles(
    activeProfileID: string,
    defaultProfileID: string | null,
  ): OwnedAuthorityDocument {
    const candidate = this.catalog.selectProfiles(
      activeProfileID,
      defaultProfileID,
    );
    return candidate === this.catalog
      ? this
      : OwnedAuthorityDocument.read(
          this.source.set("/document", candidate.source.text()),
        );
  }
  renameProfile(
    id: string,
    name: string,
    updatedAt: string,
  ): OwnedAuthorityDocument {
    const candidate = this.catalog.renameProfile(id, name, updatedAt);
    return OwnedAuthorityDocument.read(
      this.source.set("/document", candidate.source.text()),
    );
  }
}
Object.freeze(OwnedAuthorityDocument.prototype);
