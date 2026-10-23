import {
  GAMEPAD_BUTTONS,
  decodeGamepadState,
  type GamepadState,
} from "./index.ts";
export const INPUT_PACKET_BYTES = 108;
export const INPUT_STATE_BYTES = 52;
export const INPUT_PACKET_LIMIT = 1_048_576;
const fields = [
  "leftStickX",
  "leftStickY",
  "rightStickX",
  "rightStickY",
  "leftTrigger",
  "rightTrigger",
] as const;
/** Portable semantic oracle only. Native modules own encryption and per-sample transport. */
export function encodeInputState(value: unknown): Uint8Array {
  const state = decodeGamepadState(value);
  if (GAMEPAD_BUTTONS.length !== 17)
    throw new Error("input_packet_version_required");
  const bytes = new Uint8Array(INPUT_STATE_BYTES),
    view = new DataView(bytes.buffer);
  let mask = 0;
  for (const button of state.buttons)
    mask |= 1 << GAMEPAD_BUTTONS.indexOf(button);
  view.setUint32(0, mask, true);
  fields.forEach((field, i) => view.setFloat64(4 + i * 8, state[field], true));
  return bytes;
}
export function decodeInputState(bytes: Uint8Array): GamepadState {
  if (bytes.length !== INPUT_STATE_BYTES || GAMEPAD_BUTTONS.length !== 17)
    throw new Error("invalid_input_payload");
  const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength),
    mask = v.getUint32(0, true);
  if (mask >>> 17) throw new Error("invalid_input_payload");
  return decodeGamepadState({
    buttons: GAMEPAD_BUTTONS.filter((_, i) => (mask & (1 << i)) !== 0),
    leftStickX: v.getFloat64(4, true),
    leftStickY: v.getFloat64(12, true),
    rightStickX: v.getFloat64(20, true),
    rightStickY: v.getFloat64(28, true),
    leftTrigger: v.getFloat64(36, true),
    rightTrigger: v.getFloat64(44, true),
  });
}
