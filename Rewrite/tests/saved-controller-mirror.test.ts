import { expect, test } from "bun:test";
import { starterConfiguration } from "@thumble/domain/starter-configuration";
import { OwnedConfigurationDocument } from "@thumble/domain/owned-configuration";
import { projectSavedController } from "@thumble/domain/saved-controller-map";
import { LosslessJson } from "@thumble/contracts/json";
import { digest } from "./helpers/wow-refresh.ts";
const profileId = "aaaaaaaa-0000-0000-0000-000000000001";
function source(mutate: (mirror: LosslessJson) => LosslessJson = (v) => v) {
  const base = starterConfiguration(profileId, "Mirror proof", "1"),
    element = base.get("/profiles/0/customization/elements/0")!;
  const mirror = LosslessJson.parse("{}")
    .set("/id", element.get("/id")!.text())
    .set("/controlKind", '"joystick"')
    .set("/label", '"Presentation label"')
    .set(
      "/layout",
      element.get("/layout")!.set("/shadowStrength", "0.5").text(),
    )
    .set(
      "/joystickOutputSettings",
      element.get("/joystickOutputSettings")!.text(),
    );
  return base.set(
    "/profiles/0/customization/customButtons",
    `[${mutate(mirror).text()}]`,
  );
}
function project(value: LosslessJson) {
  return projectSavedController(
    {
      document: OwnedConfigurationDocument.read(value, digest),
      authorityRevision: "1",
    },
    { profileId, authorityRevision: "1", sourceSha256: digest(value.text()) },
    { generation: "1", revision: "1" },
    { width: 874, height: 393 },
    digest,
  );
}
test("presentation mirrors retain source while proving the same canonical hit region and analog semantics", () => {
  const value = source(),
    before = value.text(),
    result = project(value);
  expect(result.map.controls).toHaveLength(18);
  expect(result.map.controls[0]!.action).toBe("leftStandardStick");
  expect(value.text()).toBe(before);
});
test("conflicting or additional mirror input declarations fail closed", () => {
  for (const mutate of [
    (v: LosslessJson) => v.set("/layout/centerX", "0.32"),
    (v: LosslessJson) => v.set("/layout/hitInsets/top", "1"),
    (v: LosslessJson) => v.set("/layout/isHidden", "true"),
    (v: LosslessJson) => v.set("/layout/zIndex", "1"),
    (v: LosslessJson) => v.set("/layout/hapticStyle", '"none"'),
    (v: LosslessJson) => v.set("/layout/joystickVisualStyle", '"thumbstick"'),
    (v: LosslessJson) => v.set("/id", '"bbbbbbbb-0000-0000-0000-000000000002"'),
    (v: LosslessJson) => v.set("/controlKind", '"button"'),
    (v: LosslessJson) => v.set("/joystickOutputSettings/deadZone", "0.13"),
    (v: LosslessJson) => v.set("/output", '{"gamepadButtons":["south"]}'),
    (v: LosslessJson) => v.set("/joystickMapping", "{}"),
    (v: LosslessJson) => v.set("/futureInput", "{}"),
    (v: LosslessJson) => v.set("/triggerSettings", "{}"),
  ])
    expect(() => project(source(mutate))).toThrow();
});
test("explicit empty profile outputs remain authoritative despite a valid presentation mirror", () => {
  const value = source()
    .set("/profileOutputBindings/" + profileId, "{}")
    .set("/outputBindings", "{}");
  expect(() => project(value)).toThrow("saved_controller_unbound_control");
  expect(value.get("/profileOutputBindings/" + profileId)?.text()).toBe("{}");
});
