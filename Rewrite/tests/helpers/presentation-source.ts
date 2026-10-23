import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { LosslessJson } from "@thumble/contracts/json";
const fixture = JSON.parse(
  readFileSync(
    resolve(
      import.meta.dir,
      "../../packages/fixtures/saved-controller-presentation-control-v10.json",
    ),
    "utf8",
  ),
);
const southId = "ce000000-0000-0000-0000-00000000000a";
export function withPresentation(
  source: LosslessJson,
  iconName = "Observed icon",
): LosslessJson {
  const png = fixture.iconReply.pngBase64;
  const variants = [];
  for (const colorScheme of ["light", "dark"])
    for (const actionSet of [
      "base",
      "left-trigger",
      "right-trigger",
      "both-triggers",
    ])
      variants.push({
        colorScheme,
        actionSet,
        appearance: {
          accentStyle: "blue",
          showsButtonLabels: true,
          topBar: {},
          controlBar: {},
          controls: {
            [southId]: {
              icon: {
                source: "asset",
                value: "observed-icon",
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
                id: "observed-icon",
                name: iconName,
                role: "icon",
                contentType: "image/png",
                byteCount: Buffer.from(png, "base64").length,
                data: png,
              },
            ],
          },
        },
      });
  return source.set(
    "/profiles/0/appearanceBank",
    JSON.stringify({ schemaVersion: 1, variants }),
  );
}
