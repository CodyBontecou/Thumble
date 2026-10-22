import {
  decodeControlMap,
  type ControlAction,
  type ControlMap,
  type ControlRegion,
} from "@thumble/contracts/mobile-input";

function region(
  action: ControlAction,
  x: number,
  y: number,
  width: number,
  height: number,
): ControlRegion {
  return { id: `standard-${action}`, action, x, y, width, height };
}
// Normalized inside the native input surface's safe content rectangle. React
// presentation and native hit testing must use this same rectangle and map.
const controls = decodeControlMap({
  version: 1,
  generation: "1",
  revision: "0",
  controls: [
    region("leftStick", 0.05, 0.56, 0.24, 0.38),
    region("rightStick", 0.71, 0.56, 0.24, 0.38),
    region("dpadUp", 0.12, 0.08, 0.07, 0.12),
    region("dpadLeft", 0.04, 0.21, 0.07, 0.12),
    region("dpadRight", 0.2, 0.21, 0.07, 0.12),
    region("dpadDown", 0.12, 0.34, 0.07, 0.12),
    region("north", 0.81, 0.08, 0.07, 0.12),
    region("west", 0.73, 0.21, 0.07, 0.12),
    region("east", 0.89, 0.21, 0.07, 0.12),
    region("south", 0.81, 0.34, 0.07, 0.12),
    region("leftShoulder", 0.3, 0.08, 0.12, 0.12),
    region("rightShoulder", 0.58, 0.08, 0.12, 0.12),
    region("leftTrigger", 0.3, 0.25, 0.12, 0.18),
    region("rightTrigger", 0.58, 0.25, 0.12, 0.18),
    region("select", 0.43, 0.3, 0.06, 0.12),
    region("start", 0.51, 0.3, 0.06, 0.12),
    region("home", 0.465, 0.08, 0.07, 0.12),
    region("leftStickPress", 0.33, 0.7, 0.1, 0.14),
    region("rightStickPress", 0.57, 0.7, 0.1, 0.14),
  ],
}).controls;

/** Initial landscape controller. Epochs come from native admission; this helper
 * never invents or increments them, connects output, or replays touch state. */
export function standardControllerMap(
  generation: string,
  revision: string,
): ControlMap {
  return decodeControlMap({ version: 1, generation, revision, controls });
}
