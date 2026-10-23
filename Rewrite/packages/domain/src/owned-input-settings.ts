import type { LosslessJson } from "@thumble/contracts/json";
import { field, invalidOwned, object } from "./owned-json.ts";

export type OwnedJoystickSettings = Readonly<{
  kind: "joystick";
  analogTarget: "none" | "left_stick" | "right_stick" | "mouse_look";
  sendsDigitalDirections: boolean;
  deadZone: number;
  sensitivity: number;
  invertX: boolean;
  invertY: boolean;
  snapToCardinal: boolean;
}>;
export type OwnedTriggerSettings = Readonly<{
  kind: "trigger";
  target: "left" | "right";
  orientation: "vertical" | "horizontal";
  deadZone: number;
  sensitivity: number;
  sendsDigitalButton: boolean;
  digitalThreshold: number;
}>;
export type OwnedTrackpadSettings = Readonly<{
  kind: "trackpad";
  sensitivity: number;
  scrollSensitivity: number;
  naturalScrolling: boolean;
  tapToClick: boolean;
  twoFingerScroll: boolean;
  clickButton: "left" | "right" | "middle" | null;
  movesCursor: boolean;
}>;
export type OwnedInputSettings =
  | OwnedJoystickSettings
  | OwnedTriggerSettings
  | OwnedTrackpadSettings;

function flag(
  value: LosslessJson | undefined,
  key: string,
  fallback: boolean,
): boolean {
  if (!value) return fallback;
  const result = value.get("/" + key)?.booleanValue;
  if (result === undefined) invalidOwned();
  return result;
}
function number(
  value: LosslessJson | undefined,
  key: string,
  fallback: number,
  lower: number,
  upper: number,
): number {
  if (!value) return fallback;
  const token = value.get("/" + key)?.numberToken;
  if (token === undefined) invalidOwned();
  const result = Number(token);
  if (!Number.isFinite(result)) invalidOwned();
  return Math.max(lower, Math.min(upper, result));
}
function choice<const T extends string>(
  value: LosslessJson | undefined,
  key: string,
  fallback: T,
  choices: readonly T[],
): T {
  if (!value) return fallback;
  const result = value.get("/" + key)?.stringValue;
  const found = choices.find((candidate) => candidate === result);
  if (found === undefined) invalidOwned();
  return found;
}
/** Normalized input semantics only. Omitted/null settings use native defaults;
 * present records require the native Codable fields. Exact source and unknown
 * extension fields stay untouched. This is not an activation/platform check. */
export function readOwnedInputSettings(
  kind: string,
  source: LosslessJson,
): OwnedInputSettings | null {
  const key =
    kind === "joystick"
      ? "joystickOutputSettings"
      : kind === "trigger"
        ? "triggerSettings"
        : kind === "trackpad"
          ? "trackpadSettings"
          : undefined;
  if (!key) return null;
  const value = field(source, key);
  if (value) object(value);
  if (kind === "joystick") {
    const analogTarget = choice(value, "analogTarget", "none", [
      "none",
      "left_stick",
      "right_stick",
      "mouse_look",
    ]);
    const digital = flag(value, "sendsDigitalDirections", true);
    return Object.freeze({
      kind,
      analogTarget,
      sendsDigitalDirections:
        analogTarget !== "mouse_look" && (digital || analogTarget === "none"),
      deadZone: number(value, "deadZone", 0.12, 0, 0.85),
      sensitivity: number(value, "sensitivity", 1, 0.2, 3),
      invertX: flag(value, "invertX", false),
      invertY: flag(value, "invertY", false),
      snapToCardinal: flag(value, "snapToCardinal", false),
    });
  }
  if (kind === "trigger")
    return Object.freeze({
      kind,
      target: choice(value, "target", "right", ["left", "right"]),
      orientation: choice(value, "orientation", "vertical", [
        "vertical",
        "horizontal",
      ]),
      deadZone: number(value, "deadZone", 0.03, 0, 0.85),
      sensitivity: number(value, "sensitivity", 1, 0.2, 3),
      sendsDigitalButton: flag(value, "sendsDigitalButton", false),
      digitalThreshold: number(value, "digitalThreshold", 0.5, 0.01, 1),
    });
  const button = value ? field(value, "clickButton") : undefined;
  const moves = value ? field(value, "movesCursor") : undefined;
  if (moves && moves.booleanValue === undefined) invalidOwned();
  return Object.freeze({
    kind: "trackpad",
    sensitivity: number(value, "sensitivity", 1.2, 0.2, 4),
    scrollSensitivity: number(value, "scrollSensitivity", 0.85, 0.1, 4),
    naturalScrolling: flag(value, "naturalScrolling", true),
    tapToClick: flag(value, "tapToClick", true),
    twoFingerScroll: flag(value, "twoFingerScroll", true),
    clickButton: button
      ? choice(value, "clickButton", "left", ["left", "right", "middle"])
      : null,
    movesCursor: moves?.booleanValue ?? true,
  });
}
