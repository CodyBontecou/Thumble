import type { GamepadButton, GamepadState } from "@thumble/contracts";

const buttonBits: Record<GamepadButton, number | null> = {
  dpadUp: 0, dpadDown: 1, dpadLeft: 2, dpadRight: 3, start: 4, select: 5,
  leftStickPress: 6, rightStickPress: 7, leftShoulder: 8, rightShoulder: 9,
  home: 10, south: 12, east: 13, west: 14, north: 15,
  leftTriggerButton: null, rightTriggerButton: null,
};
const finite = (value: number): number => Number.isFinite(value) ? value : 0;
const clamp = (value: number, minimum: number): number => Math.min(1, Math.max(minimum, finite(value)));
// Swift/Rust round signed ties away from zero; Math.round has different negative ties.
const roundAway = (value: number): number => Math.sign(value) * Math.round(Math.abs(value));

/** Retained v2 report conformance oracle. No OS imports, device creation or I/O. */
export function encodeGamepadReport(state: GamepadState): Uint8Array {
  const buttons = new Set(state.buttons);
  let mask = 0;
  for (const button of buttons) {
    const bit = buttonBits[button];
    if (bit !== null) mask |= 1 << bit;
  }
  if (buttons.has("dpadUp") && buttons.has("dpadDown")) mask &= ~3;
  if (buttons.has("dpadLeft") && buttons.has("dpadRight")) mask &= ~12;
  const report = new Uint8Array(20);
  const view = new DataView(report.buffer);
  report[1] = 20;
  view.setUint16(2, mask, true);
  report[4] = Math.round(clamp(buttons.has("leftTriggerButton") ? 1 : state.leftTrigger, 0) * 255);
  report[5] = Math.round(clamp(buttons.has("rightTriggerButton") ? 1 : state.rightTrigger, 0) * 255);
  const axes = [state.leftStickX, -state.leftStickY, state.rightStickX, -state.rightStickY];
  axes.forEach((value, index) => {
    const bounded = clamp(value, -1);
    view.setInt16(6 + index * 2, roundAway(bounded * (bounded < 0 ? 32768 : 32767)), true);
  });
  return report;
}
