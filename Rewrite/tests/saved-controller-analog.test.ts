import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { createHash } from "node:crypto";
import { LosslessJson } from "@thumble/contracts/json";
import { decodeControlMap } from "@thumble/contracts/mobile-input";
import {
  decodePhoneControlsQuery,
  decodePhoneControlsResult,
} from "@thumble/contracts/phone-controls";
import { ConfigurationPhoneControlsOperations } from "@thumble/application/configuration-phone-controls";
import { configurationSourceHash } from "@thumble/storage";
import { OwnedConfigurationDocument } from "@thumble/domain/owned-configuration";
import { projectSavedController } from "@thumble/domain/saved-controller-map";
const root = resolve(import.meta.dir, "../packages/fixtures"),
  hash = (x: string | Uint8Array) =>
    createHash("sha256").update(x).digest("hex");
const source = () =>
  LosslessJson.parse(
    readFileSync(resolve(root, "saved-controller-analog-v1.json"), "utf8"),
  );
const profileId = "bbbbbbbb-0000-0000-0000-000000000002",
  base = "/profiles/1/customization/elements";
const wire = JSON.parse(
  readFileSync(
    resolve(root, "saved-controller-analog-control-v8.json"),
    "utf8",
  ),
);
function project(value = source(), width = 874, height = 393) {
  return projectSavedController(
    {
      document: OwnedConfigurationDocument.read(value, hash),
      authorityRevision: "3",
    },
    { profileId, authorityRevision: "3", sourceSha256: hash(value.text()) },
    { generation: "7", revision: "2" },
    { width, height },
    hash,
  );
}
test("saved selected movement/camera and independent continuous triggers preserve retained geometry, opaque source and immutable authority pins", () => {
  const value = source(),
    before = value.text(),
    result = project(value);
  expect(result.map.controls.map((c) => c.action)).toEqual([
    "leftStandardStick",
    "rightStandardStick",
    "leftVerticalTrigger",
    "rightHorizontalTrigger",
    "south",
  ]);
  expect(result.map.controls.map((c) => c.id)).toEqual(
    [1, 2, 3, 4]
      .map((n) => `de000000-0000-0000-0000-${String(n).padStart(12, "0")}`)
      .concat("db000000-0000-0000-0000-000000000002"),
  );
  const [movement, camera, left, right] = result.map.controls;
  for (const stick of [movement!, camera!]) {
    expect(stick.width * 874).toBeCloseTo(117.9, 10);
    expect(stick.height * 393).toBeCloseTo(117.9, 10);
    expect(stick.y + stick.height / 2).toBeCloseTo(0.6, 12);
  }
  expect(movement!.x + movement!.width / 2).toBeCloseTo(0.2, 12);
  expect(camera!.x + camera!.width / 2).toBeCloseTo(0.8, 12);
  for (const trigger of [left!, right!]) {
    expect(trigger.width * 874).toBeCloseTo(117.9, 10);
    expect(trigger.height * 393).toBeCloseTo(43.23, 10);
    expect(trigger.y + trigger.height / 2).toBeCloseTo(0.15, 12);
  }
  expect(value.text()).toBe(before);
  expect(value.get("/futureExactNumber")!.text()).toBe("9007199254740993.0");
  expect(
    value.get(base + "/0/futureControllerMetadata/owner")!.stringValue,
  ).toBe("preserve exact opaque source");
  expect(Object.isFrozen(result.map.controls)).toBe(true);
  expect(result.sourceSha256).toBe(hash(before));
});
test("complete saved analog source produces the shared scalar reply through actual sole-owner operation without committing", () => {
  const value = source(),
    { version: _v, command: _c, connectionId: _i, ...body } = wire.request;
  const query = decodePhoneControlsQuery({
    authorityInstanceId: "synthetic-authority",
    ...body,
  });
  let writes = 0;
  const operations = new ConfigurationPhoneControlsOperations(
    {
      current: () => ({
        source: value,
        revision: "3",
        contentHash: configurationSourceHash(value),
      }),
      receipt: () => undefined,
      commit: () => {
        writes++;
        throw Error("read only");
      },
    },
    {
      sourceHash: configurationSourceHash,
      documentHash: hash,
      resourceHash: hash,
      readAsset: () => {
        throw Error("no resources");
      },
    },
  );
  const actual = operations.execute({
    command: "configuration-phone-controls",
    ...query,
  });
  const {
    version: _rv,
    command: _rc,
    connectionId: _ri,
    ...expected
  } = wire.reply;
  expect(actual).toEqual(expected);
  expect(decodePhoneControlsResult(actual, query)).toEqual(expected);
  expect(writes).toBe(0);
  expect(wire.request.expectedSourceHash).toBe(configurationSourceHash(value));
  expect(wire.reply.configurationSha256).toBe(hash(value.text()));
  expect(wire.reply.configurationSha256).not.toBe(wire.reply.sourceHash);
});
test("analog mappings never approximate unsupported retained settings, pointer semantics, digital bindings or interaction geometry", () => {
  const input = source();
  for (const [path, text, code] of [
    [
      base + "/0/joystickOutputSettings/analogTarget",
      '"mouse_look"',
      "unsupported_analog_settings",
    ],
    [
      base + "/0/joystickOutputSettings/analogTarget",
      '"none"',
      "unsupported_analog_settings",
    ],
    [
      base + "/0/joystickOutputSettings/sendsDigitalDirections",
      "true",
      "unsupported_analog_settings",
    ],
    [
      base + "/0/joystickOutputSettings/deadZone",
      "0.1",
      "unsupported_analog_settings",
    ],
    [
      base + "/0/joystickOutputSettings/sensitivity",
      "2",
      "unsupported_analog_settings",
    ],
    [
      base + "/0/joystickOutputSettings/invertX",
      "true",
      "unsupported_analog_settings",
    ],
    [
      base + "/0/joystickOutputSettings/invertY",
      "true",
      "unsupported_analog_settings",
    ],
    [
      base + "/0/joystickOutputSettings/snapToCardinal",
      "true",
      "unsupported_analog_settings",
    ],
    [
      base + "/0/layout/joystickVisualStyle",
      '"thumbstick"',
      "unsupported_analog_settings",
    ],
    [
      base + "/2/triggerSettings/deadZone",
      "0.1",
      "unsupported_analog_settings",
    ],
    [
      base + "/2/triggerSettings/sensitivity",
      "2",
      "unsupported_analog_settings",
    ],
    [
      base + "/2/triggerSettings/sendsDigitalButton",
      "true",
      "unsupported_analog_settings",
    ],
    [
      base + "/2/triggerSettings/digitalThreshold",
      "0.7",
      "unsupported_analog_settings",
    ],
    [base + "/0/output", '{"gamepadButtons":["south"]}', "unsupported_binding"],
    [
      base + "/0/defaultOutput",
      '{"keyboard":{"keyCode":1}}',
      "unsupported_binding",
    ],
    [base + "/0/partOutputs", '{"joystick_up":{}}', "unsupported_binding"],
    [
      base + "/0/defaultPartOutputs",
      '{"joystick_up":{}}',
      "unsupported_binding",
    ],
    [
      base + "/0/joystickMapping",
      '{"up":{},"down":{},"left":{},"right":{}}',
      "unsupported_binding",
    ],
    [base + "/2/layout/hitInsets/top", "10", "unsupported_hit_insets"],
    [base + "/0/layout/widthScale", "0.001", "unsupported_geometry"],
    [base + "/2/layout/heightScale", "0.001", "unsupported_geometry"],
    [base + "/0/layout/rotationDegrees", "90", "unsupported_transform"],
    [base + "/0/layout/shape", '"rectangle"', "unsupported_transform"],
    [base + "/0/layout/zIndex", "1", "unsupported_transform"],
    [base + "/0/layout/widthScale", "12", "unsupported_geometry"],
  ] as const)
    expect(() => project(input.set(path, text))).toThrow(
      "saved_controller_" + code,
    );
  expect(() => project(input.remove(base + "/0/layout/hitInsets"))).toThrow(
    "saved_controller_unsupported_hit_insets",
  );
  const outputPath =
    "/profileOutputBindings/" +
    profileId +
    "/de000000-0000-0000-0000-000000000001";
  expect(() =>
    project(input.set(outputPath, '{"gamepadButtons":["north"]}')),
  ).toThrow("saved_controller_unsupported_binding");
  const keyboardPath =
    "/profileKeyBindings/" +
    profileId +
    "/de000000-0000-0000-0000-000000000001";
  expect(() => project(input.set(keyboardPath, '{"keyCode":1}'))).toThrow(
    "saved_controller_unsupported_binding",
  );
});
test("all six exact semantic actions are supported without reusing legacy actions or allowing duplicate analog target ownership", () => {
  const input = source();
  expect(
    project(input.set(base + "/2/triggerSettings/orientation", '"horizontal"'))
      .map.controls[2]!.action,
  ).toBe("leftHorizontalTrigger");
  expect(
    project(input.set(base + "/3/triggerSettings/orientation", '"vertical"'))
      .map.controls[3]!.action,
  ).toBe("rightVerticalTrigger");
  expect(() =>
    project(
      input.set(
        base + "/1/joystickOutputSettings/analogTarget",
        '"left_stick"',
      ),
    ),
  ).toThrow("saved_controller_duplicate_analog_target");
  expect(() =>
    project(input.set(base + "/3/triggerSettings/target", '"left"')),
  ).toThrow("saved_controller_duplicate_analog_target");
  const map = project().map;
  for (const action of [
    "leftStandardStick",
    "rightStandardStick",
    "leftVerticalTrigger",
    "rightVerticalTrigger",
    "leftHorizontalTrigger",
    "rightHorizontalTrigger",
    "leftStick",
    "rightStick",
    "leftTrigger",
    "rightTrigger",
  ] as const) {
    expect(
      decodeControlMap({ ...map, controls: [{ ...map.controls[0]!, action }] })
        .controls[0]!.action,
    ).toBe(action);
  }
  for (const action of [
    "leftStandardStick ",
    "LeftStandardStick",
    "leftStandardStick:0.12",
    "mouseLook",
    "leftContinuousTrigger",
  ])
    expect(() =>
      decodeControlMap({ ...map, controls: [{ ...map.controls[0]!, action }] }),
    ).toThrow("invalid_control_map");
});
