import { GAMEPAD_BUTTONS, type GamepadButton, type GamepadState } from "./gamepad.generated.ts";
export { GAMEPAD_BUTTONS, type GamepadButton, type GamepadState } from "./gamepad.generated.ts";

export class ContractError extends Error {
  readonly code = "invalid_gamepad_state";
  constructor(readonly path: string, expected: string) {
    super(`${path}: expected ${expected}`);
    this.name = "ContractError";
  }
}

const fields = ["leftStickX", "leftStickY", "rightStickX", "rightStickY", "leftTrigger", "rightTrigger"] as const;
const keys = new Set<string>(["buttons", ...fields]);
const knownButtons = new Set<string>(GAMEPAD_BUTTONS);

export function isGamepadButton(value: unknown): value is GamepadButton {
  return typeof value === "string" && knownButtons.has(value);
}

/** Value-level validator. Byte/duplicate-key limits belong to the transport codec. */
export function decodeGamepadState(value: unknown): GamepadState {
  if (typeof value !== "object" || value === null || Array.isArray(value) ||
      ![Object.prototype, null].includes(Object.getPrototypeOf(value))) {
    throw new ContractError("state", "plain object");
  }
  for (const key of Reflect.ownKeys(value)) {
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (typeof key !== "string" || !keys.has(key) || !descriptor || !("value" in descriptor)) {
      throw new ContractError("state", "known data fields only");
    }
  }
  const state = value as Record<string, unknown>;
  if (!Array.isArray(state.buttons) || state.buttons.length > GAMEPAD_BUTTONS.length ||
      ![...state.buttons].every(isGamepadButton) || new Set(state.buttons).size !== state.buttons.length) {
    throw new ContractError("state.buttons", "bounded unique semantic buttons");
  }
  for (const field of fields) {
    const number = state[field];
    const minimum = field.endsWith("Trigger") ? 0 : -1;
    if (typeof number !== "number" || !Number.isFinite(number) || number < minimum || number > 1) {
      throw new ContractError(`state.${field}`, `finite number in ${minimum}...1`);
    }
  }
  // Reconstruct ownership; callers cannot mutate an activated state through their source object.
  return Object.freeze({
    buttons: Object.freeze([...state.buttons]),
    leftStickX: state.leftStickX as number, leftStickY: state.leftStickY as number,
    rightStickX: state.rightStickX as number, rightStickY: state.rightStickY as number,
    leftTrigger: state.leftTrigger as number, rightTrigger: state.rightTrigger as number,
  });
}

export function neutralGamepadState(): GamepadState {
  return Object.freeze({ buttons: Object.freeze([]), leftStickX: 0, leftStickY: 0,
    rightStickX: 0, rightStickY: 0, leftTrigger: 0, rightTrigger: 0 });
}
