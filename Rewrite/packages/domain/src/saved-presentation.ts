import type { PresentationBank } from "@thumble/contracts/phone-presentation";
import type { ControlMap } from "@thumble/contracts/mobile-input";
import type { LosslessJson } from "@thumble/contracts/json";
import type {
  OwnedConfigurationDocument,
  ResourceDigest,
} from "./owned-configuration.ts";
import { decodeResourceBase64 } from "./owned-resources.ts";
import { uuidPairs } from "./owned-json.ts";
import { wowLiveUtf8Size } from "./wow-live-utf8.ts";
export type SavedControlPresentation = Readonly<{
  id: string;
  label: string;
  icon?: Readonly<{ sha256: string; name: string; bytes: Uint8Array }>;
}>;
export type SavedPresentation = Readonly<{
  profileName: string;
  controls: readonly SavedControlPresentation[];
}>;
function unsupported(): never {
  throw Error("saved_presentation_unsupported");
}
function label(value: LosslessJson | undefined): string {
  const text = value?.stringValue ?? (value === undefined ? "" : undefined);
  if (text === undefined || wowLiveUtf8Size(text) > 128) unsupported();
  return text;
}
/** Exact requested bank/theme assets and labels only. No skin layout, modifier selection,
 * capture freshness, source writes or runtime/input authority are inferred here. */
export function projectSavedPresentation(
  document: OwnedConfigurationDocument,
  profileId: string,
  colorScheme: "light" | "dark",
  map: ControlMap,
  digest: ResourceDigest,
  bank?: PresentationBank,
): SavedPresentation {
  const index = document.catalog.profiles.findIndex(
    (profile) => profile.id === profileId,
  );
  if (index < 0) unsupported();
  const profile = document.profiles[index]!,
    source = profile.source,
    customization = source.get("/customization")!;
  const labels = uuidPairs(customization.get("/labelOverrides"));
  const variants = source.get("/appearanceBank/variants");
  let appearance: LosslessJson | undefined, reference: LosslessJson | undefined;
  if (variants) {
    const matching = Array.from(
      { length: variants.length! },
      (_, i) => variants.get("/" + i)!,
    ).filter(
      (v) =>
        v.get("/actionSet")?.stringValue === (bank ?? "base") &&
        v.get("/colorScheme")?.stringValue === colorScheme,
    );
    if (matching.length !== 1) unsupported();
    appearance = matching[0]!.get("/appearance");
    if (bank !== undefined) {
      const bases = Array.from(
        { length: variants.length! },
        (_, i) => variants.get("/" + i)!,
      ).filter(
        (v) =>
          v.get("/actionSet")?.stringValue === "base" &&
          v.get("/colorScheme")?.stringValue === "light",
      );
      if (bases.length !== 1) unsupported();
      reference = bases[0]!.get("/appearance");
    }
  }
  const equal = (
    a: LosslessJson | undefined,
    b: LosslessJson | undefined,
  ): boolean =>
    JSON.stringify(
      JSON.parse(a && a.kind !== "null" ? a.canonicalText() : "null"),
    ) ===
    JSON.stringify(
      JSON.parse(b && b.kind !== "null" ? b.canonicalText() : "null"),
    );
  const iconValue = (
    value: LosslessJson | undefined,
  ): LosslessJson | undefined =>
    value?.get("/tintColor")?.kind === "null"
      ? value.remove("/tintColor")
      : value;
  const assets = (v: LosslessJson | undefined): Map<string, LosslessJson> => {
    const result = new Map<string, LosslessJson>();
    if (!v) return result;
    if (v.kind !== "array") unsupported();
    for (let i = 0; i < v.length!; i++) {
      const asset = v.get("/" + i)!,
        id = asset.get("/id")?.stringValue;
      if (!id || result.has(id)) unsupported();
      result.set(id, asset);
    }
    return result;
  };
  const library = assets(appearance?.get("/assetLibrary/assets"));
  // Retained three-way library ownership: edited/missing reference entries win;
  // unchanged entries use the selected state's bytes; new edits are added.
  if (reference) {
    const base = assets(reference.get("/assetLibrary/assets")),
      edited = assets(customization.get("/assetLibrary/assets"));
    if (edited.size === 0 && base.size > 0) library.clear();
    for (const [id, asset] of library) {
      const old = base.get(id),
        current = edited.get(id);
      if (old) {
        if (!current) library.delete(id);
        else if (!equal(current, old)) library.set(id, current);
      } else if (current) library.set(id, current);
    }
    for (const [id, asset] of edited)
      if (!library.has(id) && !equal(asset, base.get(id)))
        library.set(id, asset);
  }
  const controls = map.controls.map((control) => {
    const element = profile.elements.find(
      (element) => element.id === control.id,
    );
    if (!element) unsupported();
    const result: {
      id: string;
      label: string;
      icon?: Readonly<{ sha256: string; name: string; bytes: Uint8Array }>;
    } = {
      id: control.id,
      label: label(labels.get(control.id) ?? element.source.get("/label")),
    };
    const directIcon = element.source.get("/layout/icon");
    if (!variants && directIcon && directIcon.kind !== "null") unsupported();
    let icon = appearance?.get("/controls/" + control.id + "/icon");
    // A direct canonical edit/removal is relative to saved light/base, not the
    // currently selected bank. Never resurrect an icon the user removed.
    if (
      reference &&
      !equal(
        iconValue(directIcon),
        iconValue(reference.get("/controls/" + control.id + "/icon")),
      )
    )
      icon = directIcon;
    if (icon && icon.kind !== "null") {
      if (
        icon.get("/source")?.stringValue !== "asset" ||
        icon.get("/renderingMode")?.stringValue !== "original"
      )
        unsupported();
      const assetId = icon.get("/value")?.stringValue;
      if (!assetId) unsupported();
      const asset = library.get(assetId);
      if (!asset) unsupported();
      const count = Number(asset.get("/byteCount")?.numberToken);
      if (
        asset.get("/contentType")?.stringValue !== "image/png" ||
        !Number.isSafeInteger(count) ||
        count < 57 ||
        count > 8192
      )
        unsupported();
      const data = asset.get("/data");
      let bytes: Uint8Array;
      if (data?.kind === "object") {
        if (
          !profile.resources ||
          profile.resources.referenceSize(data) !== count
        )
          unsupported();
        bytes = profile.resources.data(data);
      } else {
        const encoded = data?.stringValue;
        if (!encoded || encoded.length > 10924) unsupported();
        bytes = decodeResourceBase64(encoded);
      }
      if (bytes.length !== count) unsupported();
      const sha256 = digest(bytes.slice());
      if (!/^[a-f0-9]{64}$/.test(sha256)) unsupported();
      result.icon = Object.freeze({
        sha256,
        name: label(asset.get("/name")),
        bytes: bytes.slice(),
      });
    }
    return Object.freeze(result);
  });
  return Object.freeze({
    profileName: label(source.get("/name")),
    controls: Object.freeze(controls),
  });
}
