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
  | "rightTrigger"
  | "leftStandardStick"
  | "rightStandardStick"
  | "leftVerticalTrigger"
  | "rightVerticalTrigger"
  | "leftHorizontalTrigger"
  | "rightHorizontalTrigger";
export type TouchHapticFeedback = Readonly<{
  style: "none" | "light" | "medium" | "heavy" | "soft" | "rigid";
  pattern: "single" | "double" | "pulse" | "buzz";
  intensity: number;
  sharpness: number;
  duration: number;
}>;
export function decodeTouchHapticFeedback(value: unknown): TouchHapticFeedback {
  const v = dataObject(value, [
    "style",
    "pattern",
    "intensity",
    "sharpness",
    "duration",
  ]);
  if (
    typeof v.style !== "string" ||
    !["none", "light", "medium", "heavy", "soft", "rigid"].includes(v.style) ||
    typeof v.pattern !== "string" ||
    !["single", "double", "pulse", "buzz"].includes(v.pattern) ||
    [v.intensity, v.sharpness, v.duration].some(
      (n) => typeof n !== "number" || !Number.isFinite(n),
    ) ||
    Number(v.intensity) < 0 ||
    Number(v.intensity) > 1 ||
    Number(v.sharpness) < 0 ||
    Number(v.sharpness) > 1 ||
    Number(v.duration) < 0.02 ||
    Number(v.duration) > 0.3
  )
    throw new Error("invalid_control_map");
  return Object.freeze(
    v.style === "none"
      ? { ...v, pattern: "single", intensity: 0, sharpness: 0 }
      : v,
  ) as TouchHapticFeedback;
}
export type ControlRegion = Readonly<{
  id: string;
  action: ControlAction;
  x: number;
  y: number;
  width: number;
  height: number;
  hapticFeedback?: TouchHapticFeedback;
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
/** One acknowledgement per mounted practice view, never per-sample feedback. */
export type PracticeAdmission =
  | Readonly<{
      version: 1;
      status: "ready";
      generation: string;
      revision: string;
      practice: true;
      connected: false;
    }>
  | Readonly<{ version: 1; status: "unavailable" }>;
export function decodePracticeAdmission(value: unknown): PracticeAdmission {
  const status = Object.getOwnPropertyDescriptor(
    record(value),
    "status",
  )?.value;
  if (status === "unavailable") {
    const v = dataObject(value, ["version", "status"]);
    if (v.version !== 1) throw new Error("invalid_practice_admission");
    return Object.freeze({ version: 1, status });
  }
  const v = dataObject(value, [
    "version",
    "status",
    "generation",
    "revision",
    "practice",
    "connected",
  ]);
  if (
    v.version !== 1 ||
    status !== "ready" ||
    v.practice !== true ||
    v.connected !== false ||
    v.generation === "0"
  )
    throw new Error("invalid_practice_admission");
  return Object.freeze({
    version: 1,
    status: "ready",
    generation: counter(v.generation),
    revision: counter(v.revision),
    practice: true,
    connected: false,
  });
}
/** Native connection lifecycle metadata only; bootstrap text and credentials have no bridge form. */
export type ConnectionAdmission =
  | Readonly<{
      version: 1;
      status: "ready";
      generation: string;
      revision: string;
      practice: false;
      connected: true;
    }>
  | Readonly<{
      version: 1;
      status:
        | "waiting"
        | "pairing"
        | "connecting"
        | "cancelled"
        | "unavailable"
        | "disconnected";
    }>;
export function decodeConnectionAdmission(value: unknown): ConnectionAdmission {
  const status = Object.getOwnPropertyDescriptor(
    record(value),
    "status",
  )?.value;
  if (status !== "ready") {
    const v = dataObject(value, ["version", "status"]);
    if (v.version !== 1) throw new Error("invalid_connection_admission");
    switch (status) {
      case "waiting":
      case "pairing":
      case "connecting":
      case "cancelled":
      case "unavailable":
      case "disconnected":
        return Object.freeze({ version: 1, status });
      default:
        throw new Error("invalid_connection_admission");
    }
  }
  const v = dataObject(value, [
    "version",
    "status",
    "generation",
    "revision",
    "practice",
    "connected",
  ]);
  if (
    v.version !== 1 ||
    v.practice !== false ||
    v.connected !== true ||
    v.generation === "0"
  )
    throw new Error("invalid_connection_admission");
  return Object.freeze({
    version: 1,
    status,
    generation: counter(v.generation),
    revision: counter(v.revision),
    practice: false,
    connected: true,
  });
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
    "leftStandardStick",
    "rightStandardStick",
    "leftVerticalTrigger",
    "rightVerticalTrigger",
    "leftHorizontalTrigger",
    "rightHorizontalTrigger",
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
      const c = dataObject(raw, [
        "id",
        "action",
        "x",
        "y",
        "width",
        "height",
        ...(Object.hasOwn(record(raw), "hapticFeedback")
          ? ["hapticFeedback"]
          : []),
      ]);
      const hapticFeedback = Object.hasOwn(c, "hapticFeedback")
        ? decodeTouchHapticFeedback(c.hapticFeedback)
        : undefined;
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
        ...(hapticFeedback === undefined ? {} : { hapticFeedback }),
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
