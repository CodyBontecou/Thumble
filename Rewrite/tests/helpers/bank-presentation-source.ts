import fixture from "../../packages/fixtures/saved-controller-presentation-control-v11.json";
import { LosslessJson } from "@thumble/contracts/json";
export const bankSouthId = "ce000000-0000-0000-0000-00000000000a";
export function withBankPresentation(source: LosslessJson): LosslessJson {
  const variants = fixture.variants.map((f, i) => ({
    colorScheme: f.request.colorScheme,
    actionSet: f.request.bank,
    appearance: {
      accentStyle: "blue",
      showsButtonLabels: true,
      topBar: {},
      controlBar: {},
      controls: {
        [bankSouthId]: {
          icon: {
            source: "asset",
            value: `bank-icon-${i}`,
            placement: "top",
            renderingMode: "original",
            scale: 1,
          },
        },
      },
      artworkLayers: [],
      styleLibrary: { styles: [] },
      assetLibrary: {
        assets: [
          {
            id: `bank-icon-${i}`,
            name: f.reply.control0IconName,
            role: "icon",
            contentType: "image/png",
            byteCount: f.iconReply.byteCount,
            data: f.iconReply.pngBase64,
          },
        ],
      },
    },
  }));
  return source
    .set(
      "/profiles/0/appearanceBank",
      JSON.stringify({ schemaVersion: 1, variants }),
    )
    .set(
      "/profiles/0/customization/elements/9/layout/icon",
      JSON.stringify(variants[0]!.appearance.controls[bankSouthId].icon),
    )
    .set(
      "/profiles/0/customization/assetLibrary",
      JSON.stringify(variants[0]!.appearance.assetLibrary),
    );
}
