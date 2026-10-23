import { resolve } from "node:path";
import { standardControllerMap } from "@thumble/domain/controller-layout";
import { encodeGamepadReport } from "@thumble/domain";
import {
  GAMEPAD_BUTTONS,
  neutralGamepadState,
  type GamepadState,
  type GamepadButton,
} from "@thumble/contracts";

const map = standardControllerMap("1", "0");
const probes = map.controls.map((control) => {
  const stick =
    control.action === "leftStick" || control.action === "rightStick";
  // This fixture intentionally probes the unchanged standard template only.
  if (
    !stick &&
    control.action !== "leftTrigger" &&
    control.action !== "rightTrigger" &&
    !(GAMEPAD_BUTTONS as readonly string[]).includes(control.action)
  )
    throw new Error("unsupported_standard_fixture_action");
  const state: GamepadState = {
    ...neutralGamepadState(),
    ...(control.action === "leftStick"
      ? { leftStickX: 0.8 }
      : control.action === "rightStick"
        ? { rightStickX: 0.8 }
        : control.action === "leftTrigger"
          ? { leftTrigger: 1 }
          : control.action === "rightTrigger"
            ? { rightTrigger: 1 }
            : { buttons: [control.action as GamepadButton] }),
  };
  return {
    id: control.id,
    x: control.x + control.width * (stick ? 0.9 : 0.5),
    y: control.y + control.height * 0.5,
    reportHex: Buffer.from(encodeGamepadReport(state)).toString("hex"),
  };
});
const chord = {
  ids: [
    "leftStick",
    "rightStick",
    "leftTrigger",
    "rightTrigger",
    "south",
    "leftShoulder",
  ].map((action) => `standard-${action}`),
  reportHex: Buffer.from(
    encodeGamepadReport({
      ...neutralGamepadState(),
      buttons: ["south", "leftShoulder"],
      leftStickX: 0.8,
      rightStickX: 0.8,
      leftTrigger: 1,
      rightTrigger: 1,
    }),
  ).toString("hex"),
};
const content =
  JSON.stringify({ version: 1, map, probes, chord }, null, 2) + "\n";
const file = Bun.file(
  resolve(import.meta.dir, "../packages/fixtures/controller-layout-v1.json"),
);
if (Bun.argv.includes("--check")) {
  if (!(await file.exists()) || (await file.text()) !== content)
    throw new Error("stale_controller_layout_fixture");
} else await Bun.write(file, content);
