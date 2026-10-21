import {
  GAMEPAD_BUTTONS,
  type GamepadButton,
  type GamepadState,
} from "./index.ts";
import { counter, exact, identity, record } from "./receiver.ts";
export type ControlAction =
  | GamepadButton
  | "leftStick"
  | "rightStick"
  | "leftTrigger"
  | "rightTrigger";
export type ControlRegion = Readonly<{
  id: string;
  action: ControlAction;
  x: number;
  y: number;
  width: number;
  height: number;
}>;
export type ControlMap = Readonly<{
  version: 1;
  generation: string;
  revision: string;
  controls: readonly ControlRegion[];
}>;
export const RELEASE_REASONS = [
  "touchCancelled",
  "background",
  "screenLock",
  "rotation",
  "profileReplacement",
  "disconnected",
  "disposed",
  "practice",
  "invalidTouch",
  "transportFailure",
  "sequenceExhausted",
] as const;
export type ReleaseReason = (typeof RELEASE_REASONS)[number];
export type ActivationReceipt = Readonly<{
  version: 1;
  generation: string;
  revision: string;
}>;
export type NativeInputSnapshot = Readonly<{
  generation: string;
  connected: boolean;
  practice: boolean;
  state: GamepadState;
  lastRelease: ReleaseReason | null;
}>;
/** Configuration/inspection only. Touch events and per-sample transport never cross JS. */
export interface NativeInputModule {
  configure(map: ControlMap): Promise<ActivationReceipt>;
  setPractice(enabled: boolean): Promise<void>;
  release(reason: ReleaseReason): Promise<void>;
  snapshot(): Promise<NativeInputSnapshot>;
}
function dataObject(
  value: unknown,
  fields: readonly string[],
): Record<string, unknown> {
  const object = record(value);
  if (
    ![Object.prototype, null].includes(Object.getPrototypeOf(object)) ||
    Reflect.ownKeys(object).length !== fields.length
  )
    throw new Error("invalid_control_map");
  exact(object, fields);
  const copy: Record<string, unknown> = {};
  for (const key of fields) {
    const descriptor = Object.getOwnPropertyDescriptor(object, key);
    if (!descriptor || !("value" in descriptor))
      throw new Error("invalid_control_map");
    copy[key] = descriptor.value;
  }
  return copy;
}
export function decodeControlMap(value: unknown): ControlMap {
  const map = dataObject(value, [
    "version",
    "generation",
    "revision",
    "controls",
  ]);
  const generation = counter(map.generation),
    revision = counter(map.revision);
  if (
    map.version !== 1 ||
    generation === "0" ||
    !Array.isArray(map.controls) ||
    map.controls.length < 1 ||
    map.controls.length > 64 ||
    Object.getPrototypeOf(map.controls) !== Array.prototype ||
    Reflect.ownKeys(map.controls).length !== map.controls.length + 1
  )
    throw new Error("invalid_control_map");
  const ids = new Set<string>();
  const actions: readonly string[] = [
    ...GAMEPAD_BUTTONS,
    "leftStick",
    "rightStick",
    "leftTrigger",
    "rightTrigger",
  ];
  const sourceControls = map.controls;
  const controls = Array.from(
    { length: sourceControls.length },
    (_, index): ControlRegion => {
      const descriptor = Object.getOwnPropertyDescriptor(
        sourceControls,
        String(index),
      );
      if (!descriptor || !("value" in descriptor))
        throw new Error("invalid_control_map");
      const raw: unknown = descriptor.value;
      const c = dataObject(raw, ["id", "action", "x", "y", "width", "height"]);
      const id = identity(c.id);
      if (
        ids.has(id) ||
        typeof c.action !== "string" ||
        !actions.includes(c.action) ||
        ![c.x, c.y, c.width, c.height].every(
          (n) => typeof n === "number" && Number.isFinite(n),
        )
      )
        throw new Error("invalid_control_map");
      ids.add(id);
      const x = Number(c.x),
        y = Number(c.y),
        width = Number(c.width),
        height = Number(c.height);
      if (
        x < 0 ||
        y < 0 ||
        width < 0.001 ||
        height < 0.001 ||
        x + width > 1 ||
        y + height > 1
      )
        throw new Error("invalid_control_map");
      return Object.freeze({
        id,
        action: c.action as ControlAction,
        x,
        y,
        width,
        height,
      });
    },
  );
  return Object.freeze({
    version: 1,
    generation,
    revision,
    controls: Object.freeze(controls),
  });
}
