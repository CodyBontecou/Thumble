import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { LosslessJson } from "@thumble/contracts/json";
import { OwnedConfigurationDocument } from "@thumble/domain/owned-configuration";
import {
  projectSavedController,
  type SavedControllerPin,
} from "@thumble/domain/saved-controller-map";
const hash = (bytes: string | Uint8Array) =>
  createHash("sha256").update(bytes).digest("hex");
const id = "00000000-0000-0000-0000-000000000109",
  profileId = "ea000000-0000-0000-0000-000000000001";
const viewport = { width: 844, height: 390 };
/** Actual retained resource/appearance-bank fixture, with an explicit supported
 * rectangular controller binding saved through the same owned-v5 source form. */
function source() {
  return LosslessJson.parse(
    readFileSync(
      resolve(
        import.meta.dir,
        "../packages/fixtures/owned-configuration-v1/document.json",
      ),
      "utf8",
    ),
  )
    .set("/profiles/0/outputMode", '"controller"')
    .set(
      "/profiles/0/customization/buttonCustomizations/1/shape",
      '"rectangle"',
    )
    .set(
      `/profileOutputBindings/EA000000-0000-0000-0000-000000000001/${id}`,
      JSON.stringify({
        gamepadButtons: ["select"],
        futureBinding: { preserve: true },
      }),
    )
    .set("/futureExactNumber", "9007199254740993.0000");
}
function project(
  value = source(),
  patch: Partial<SavedControllerPin> = {},
  size = viewport,
) {
  const document = OwnedConfigurationDocument.read(value, hash);
  return projectSavedController(
    { document, authorityRevision: "12" },
    {
      profileId,
      authorityRevision: "12",
      sourceSha256: hash(value.text()),
      ...patch,
    },
    { generation: "7", revision: "4" },
    size,
    hash,
  );
}
test("saved selected resource profile projects its actual binding/retained geometry without modifying source or resources", () => {
  const input = source(),
    before = input.text();
  const result = project(input);
  expect(result.profileId).toBe(profileId);
  expect(result.authorityRevision).toBe("12");
  expect(result.sourceSha256).toBe(hash(before));
  expect(result.map.generation).toBe("7");
  expect(result.map.revision).toBe("4");
  expect(result.map.controls).toHaveLength(1);
  const button = result.map.controls[0]!;
  expect(button.id).toBe(id);
  expect(button.action).toBe("select");
  expect(button.width * 844).toBeCloseTo(66.1856, 8);
  expect(button.height * 390).toBeCloseTo(23.5296, 8);
  expect((button.x + button.width / 2) * 844).toBeCloseTo(337.6, 8);
  expect((button.y + button.height / 2) * 390).toBeCloseTo(78, 8);
  expect(input.text()).toBe(before);
  expect(input.get("/futureExactNumber")!.text()).toBe("9007199254740993.0000");
  expect(Object.isFrozen(result.map.controls[0])).toBe(true);
  expect(Object.isFrozen(result.viewport)).toBe(true);
});
test("source, selected profile and authority pins fail before projection; admission epochs remain independent", () => {
  for (const patch of [
    { profileId: "0f38b980-9d36-56b6-8425-826ea40b149d" },
    { authorityRevision: "13" },
    { sourceSha256: "0".repeat(64) },
  ])
    expect(() => project(source(), patch)).toThrow(
      "saved_controller_source_conflict",
    );
  const input = source(),
    document = OwnedConfigurationDocument.read(input, hash),
    pin = {
      profileId,
      authorityRevision: "12",
      sourceSha256: hash(input.text()),
    };
  expect(() =>
    projectSavedController(
      { document, authorityRevision: "12" },
      pin,
      { generation: "0", revision: "4" },
      viewport,
      hash,
    ),
  ).toThrow("saved_controller_invalid_map_or_admission");
  expect(project(input, { profileId: profileId.toUpperCase() }).profileId).toBe(
    profileId,
  );
  for (const size of [
    { width: 390, height: 844 },
    { width: NaN, height: 390 },
    { width: 844, height: 0 },
    { width: 5000, height: 390 },
  ])
    expect(() => project(input, {}, size)).toThrow(
      "saved_controller_unsupported_viewport",
    );
});
test("present selected map wins over direct mirrors and declarations; missing maps use configured/default control fallback only", () => {
  const input = source();
  const selected = `/profileOutputBindings/EA000000-0000-0000-0000-000000000001`;
  expect(
    project(
      input.set(
        selected,
        JSON.stringify({ [id]: { gamepadButtons: ["north"] } }),
      ),
    ).map.controls[0]!.action,
  ).toBe("north");
  expect(() => project(input.set(selected, "{}"))).toThrow(
    "saved_controller_unbound_control",
  );
  const fallback = input
    .remove(selected)
    .set(
      "/profiles/0/customization/elements/0/output",
      JSON.stringify({ gamepadButtons: ["east"] }),
    );
  expect(project(fallback).map.controls[0]!.action).toBe("east");
  expect(
    project(
      fallback
        .set("/profiles/0/customization/elements/0/output", "null")
        .set(
          "/profiles/0/customization/elements/0/defaultOutput",
          JSON.stringify({ gamepadButtons: ["west"] }),
        ),
    ).map.controls[0]!.action,
  ).toBe("west");
  expect(() =>
    project(fallback.set("/profiles/0/customization/elements/0/output", "{}")),
  ).toThrow("saved_controller_unsupported_binding");
  for (const output of [
    { gamepadButtons: ["north", "south"] },
    { gamepadButtons: ["futureAction"] },
    { gamepadButtons: ["south"], keyboard: { keyCode: 1, modifiers: 0 } },
  ])
    expect(() =>
      project(input.set(selected, JSON.stringify({ [id]: output }))),
    ).toThrow("saved_controller_unsupported_binding");
});
test("unsupported interactive semantics/geometry fail without standard-map substitution; hidden noninput elements are not mapped", () => {
  const input = source(),
    geometry = "/profiles/0/customization/buttonCustomizations/1";
  for (const [path, text, code] of [
    ["/profiles/0/outputMode", '"keyboard"', "unsupported_output_mode"],
    [
      "/profiles/0/customization/elements/0/kind",
      '"joystick"',
      "unsupported_control_kind",
    ],
    [geometry + "/shape", '"circle"', "unsupported_transform"],
    [geometry + "/rotationDegrees", "15", "unsupported_transform"],
    [geometry + "/zIndex", "2", "unsupported_transform"],
    [geometry + "/widthScale", "12", "unsupported_geometry"],
    [geometry + "/centerX", "null", "unsupported_geometry"],
    [geometry + "/isHidden", "true", "no_controls"],
    [geometry + "/hapticStyle", '"heavy"', "unsupported_haptic"],
    [
      "/profiles/0/customization/elements/0/partOutputs",
      JSON.stringify({ primary: { gamepadButtons: ["north"] } }),
      "unsupported_binding",
    ],
  ])
    expect(() => project(input.set(path!, text!))).toThrow(
      "saved_controller_" + code,
    );
  const none = project(input.set(geometry + "/hapticStyle", '"none"')).map
    .controls[0]!.hapticFeedback!;
  expect(none.style).toBe("none");
  expect(none.intensity).toBe(0);
  const explicit = {
    style: "soft",
    pattern: "double",
    intensity: 0.4,
    sharpness: 0.2,
    duration: 0.08,
  } as const;
  expect(
    project(input.set(geometry + "/hapticFeedback", JSON.stringify(explicit)))
      .map.controls[0]!.hapticFeedback,
  ).toEqual(explicit);
  const extra = {
    id: "cccccccc-0000-0000-0000-000000000003",
    kind: "text",
    layout: { shape: "star" },
    future: { opaque: true },
  };
  const list = JSON.parse(
    input.get("/profiles/0/customization/elements")!.text(),
  );
  expect(
    project(
      input.set(
        "/profiles/0/customization/elements",
        JSON.stringify([...list, extra]),
      ),
    ).map.controls,
  ).toHaveLength(1);
});
test("control bounds, overlap, legacy layout mirrors and explicit safe viewport scale fail closed", () => {
  const geometry = "/profiles/0/customization/buttonCustomizations/1";
  const edge = project(
    source()
      .set(geometry + "/centerX", "0")
      .set(geometry + "/centerY", "1"),
  );
  expect(edge.map.controls[0]!.x).toBe(0);
  expect(edge.map.controls[0]!.y + edge.map.controls[0]!.height).toBeCloseTo(
    1,
    12,
  );
  const base = project(source()).map.controls[0]!;
  const compact = project(
    source().set("/profiles/0/customization/controlScale", '"compact"'),
  ).map.controls[0]!;
  expect(compact.width / base.width).toBeCloseTo(0.86, 12);
  const ids = Array.from(
    { length: 65 },
    (_, i) => `ac000000-0000-0000-0000-${String(i + 1).padStart(12, "0")}`,
  );
  const elements = ids.map((id, i) => ({
    id,
    kind: "button",
    layout: {
      centerX: 0.05 + (i % 10) * 0.1,
      centerY: 0.05 + Math.floor(i / 10) * 0.13,
      widthScale: 0.02,
      heightScale: 0.02,
      shape: "rectangle",
    },
  }));
  function many(count: number) {
    return source()
      .set(
        "/profiles/0/customization/elements",
        JSON.stringify(elements.slice(0, count)),
      )
      .set("/profiles/0/customization/buttonCustomizations", "[]")
      .set("/profiles/0/customization/labelOverrides", "[]")
      .set("/keyBindings", "{}")
      .set("/outputBindings", "{}")
      .set("/profileKeyBindings/EA000000-0000-0000-0000-000000000001", "{}")
      .set(
        "/profileOutputBindings/EA000000-0000-0000-0000-000000000001",
        JSON.stringify(
          Object.fromEntries(
            ids
              .slice(0, count)
              .map((id) => [id, { gamepadButtons: ["south"] }]),
          ),
        ),
      );
  }
  expect(project(many(64)).map.controls).toHaveLength(64);
  expect(() => project(many(65))).toThrow("saved_controller_control_limit");
  const overlapping = many(2).set(
    "/profiles/0/customization/elements/1/layout/centerX",
    "0.05",
  );
  expect(() => project(overlapping)).toThrow(
    "saved_controller_overlapping_controls",
  );
  const mirror = many(1).set(
    "/profiles/0/customization/customButtons",
    JSON.stringify([
      {
        id: ids[0],
        controlKind: "button",
        layout: { centerX: 0.9, centerY: 0.9 },
      },
    ]),
  );
  expect(() => project(mirror)).toThrow(
    "saved_controller_unsupported_layout_mirror",
  );
});
