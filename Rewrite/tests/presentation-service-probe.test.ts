import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { LosslessJson } from "@thumble/contracts/json";
import { OwnedConfigurationDocument } from "@thumble/domain/owned-configuration";
import { projectSavedController } from "@thumble/domain/saved-controller-map";
import { projectSavedPresentation } from "@thumble/domain/saved-presentation";
import { verifyPresentationIcon } from "../apps/service/src/presentation-icon.ts";
import { syntheticSource } from "../tooling/presentation-service-probe.ts";
const digest = (data: string | Uint8Array) =>
  createHash("sha256").update(data).digest("hex");
test("synthetic real-service seed has one centered supported control and appearance-only refresh", () => {
  const initial = syntheticSource(24, "Initial spell"),
    fresh = syntheticSource(144, "Refreshed spell");
  function read(text: string) {
    const document = OwnedConfigurationDocument.read(
        LosslessJson.parse(text),
        digest,
      ),
      profileId = document.catalog.activeProfileID!;
    const projected = projectSavedController(
      { document, authorityRevision: "2" },
      { profileId, authorityRevision: "2", sourceSha256: digest(text) },
      { generation: "1", revision: "1" },
      { width: 874, height: 393 },
      digest,
    );
    expect(document.catalog.profiles).toHaveLength(1);
    expect(projected.map.controls).toHaveLength(1);
    const control = projected.map.controls[0]!;
    expect(control.action).toBe("south");
    expect(control.x + control.width / 2).toBeCloseTo(0.5, 12);
    expect(control.y + control.height / 2).toBeCloseTo(0.5, 12);
    const light = projectSavedPresentation(
        document,
        profileId,
        "light",
        projected.map,
        digest,
      ),
      dark = projectSavedPresentation(
        document,
        profileId,
        "dark",
        projected.map,
        digest,
      );
    expect(dark.controls[0]!.icon!.sha256).toBe(
      light.controls[0]!.icon!.sha256,
    );
    verifyPresentationIcon(light.controls[0]!.icon!.bytes);
    return { map: projected.map, presentation: light };
  }
  const a = read(initial),
    b = read(fresh);
  expect(a.map).toEqual(b.map);
  expect(initial).not.toBe(fresh);
  expect(a.presentation.controls[0]!.label).toBe("Initial spell");
  expect(b.presentation.controls[0]!.label).toBe("Refreshed spell");
  expect(a.presentation.controls[0]!.icon!.sha256).not.toBe(
    b.presentation.controls[0]!.icon!.sha256,
  );
  expect(syntheticSource(24, "Initial spell")).toBe(initial);
});
