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
/** Exact base/theme assets and labels only. No skin layout, modifier selection,
 * capture freshness, source writes or runtime/input authority are inferred here. */
export function projectSavedPresentation(
  document: OwnedConfigurationDocument,
  profileId: string,
  colorScheme: "light" | "dark",
  map: ControlMap,
  digest: ResourceDigest,
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
  let appearance: LosslessJson | undefined;
  if (variants) {
    const matching = Array.from(
      { length: variants.length! },
      (_, i) => variants.get("/" + i)!,
    ).filter(
      (v) =>
        v.get("/actionSet")?.stringValue === "base" &&
        v.get("/colorScheme")?.stringValue === colorScheme,
    );
    if (matching.length !== 1) unsupported();
    appearance = matching[0]!.get("/appearance");
  }
  const library = appearance?.get("/assetLibrary/assets");
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
    const icon = appearance?.get("/controls/" + control.id + "/icon");
    if (icon && icon.kind !== "null") {
      if (
        icon.get("/source")?.stringValue !== "asset" ||
        icon.get("/renderingMode")?.stringValue !== "original" ||
        !library
      )
        unsupported();
      const assetId = icon.get("/value")?.stringValue;
      if (!assetId) unsupported();
      const matches = Array.from(
        { length: library.length! },
        (_, i) => library.get("/" + i)!,
      ).filter((asset) => asset.get("/id")?.stringValue === assetId);
      if (matches.length !== 1) unsupported();
      const asset = matches[0]!;
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
