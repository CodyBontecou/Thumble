// Generated from gamepad-state-v1.schema.json; do not edit. DTO only: validate before activation.
export const GAMEPAD_BUTTONS = ["south","east","west","north","leftShoulder","rightShoulder","leftTriggerButton","rightTriggerButton","select","start","home","leftStickPress","rightStickPress","dpadUp","dpadDown","dpadLeft","dpadRight"] as const;
export type GamepadButton = (typeof GAMEPAD_BUTTONS)[number];
export interface GamepadState {
  readonly buttons: readonly GamepadButton[];
  readonly leftStickX: number;
  readonly leftStickY: number;
  readonly rightStickX: number;
  readonly rightStickY: number;
  readonly leftTrigger: number;
  readonly rightTrigger: number;
}
