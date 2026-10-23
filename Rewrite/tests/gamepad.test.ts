import { describe, expect, test } from "bun:test";
import {
  decodeGamepadState,
  isGamepadButton,
  neutralGamepadState,
  type GamepadState,
} from "@thumble/contracts";
import { encodeGamepadReport } from "@thumble/domain";
import fixture from "../../Host/fixtures/gamepad/v2.json";

function hex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join(
    "",
  );
}

describe("retained Swift/Rust v2 native report vectors", () => {
  for (const vector of fixture.vectors) {
    test(vector.name, () => {
      const buttons = (vector.buttons ?? []).map((button) => {
        if (!isGamepadButton(button))
          throw new Error("Invalid golden vector button");
        return button;
      });
      const state: GamepadState = {
        buttons,
        leftStickX: vector.leftStickX ?? 0,
        leftStickY: vector.leftStickY ?? 0,
        rightStickX: vector.rightStickX ?? 0,
        rightStickY: vector.rightStickY ?? 0,
        leftTrigger: vector.leftTrigger ?? 0,
        rightTrigger: vector.rightTrigger ?? 0,
      };
      expect(hex(encodeGamepadReport(state))).toBe(vector.hex);
    });
  }
});

test("internal oracle neutralizes nonfinite values; external validator refuses them", () => {
  const state = {
    ...neutralGamepadState(),
    leftStickX: NaN,
    rightStickY: Infinity,
    leftTrigger: -Infinity,
  };
  expect(encodeGamepadReport(state)).toEqual(
    encodeGamepadReport(neutralGamepadState()),
  );
  expect(() => decodeGamepadState(state)).toThrow();
});

test("digital trigger release restores independent analog hold", () => {
  const analog = {
    ...neutralGamepadState(),
    leftTrigger: 0.25,
    rightTrigger: 0.75,
  };
  expect(
    encodeGamepadReport({ ...analog, buttons: ["leftTriggerButton"] })[4],
  ).toBe(255);
  expect(encodeGamepadReport(analog)[4]).toBe(64);
  expect(encodeGamepadReport(analog)[5]).toBe(191);
});

test("contract rejects malformed, unknown, duplicate, missing and out-of-range data", () => {
  const valid = neutralGamepadState();
  const { rightTrigger: _omitted, ...missing } = valid;
  for (const value of [
    null,
    [],
    "state",
    missing,
    { ...valid, extra: true },
    { ...valid, buttons: ["not-a-button"] },
    { ...valid, buttons: Array(1) },
    { ...valid, buttons: ["south", "south"] },
    { ...valid, leftStickX: "0" },
    { ...valid, leftStickY: 1.01 },
    { ...valid, leftTrigger: -0.01 },
    Object.create(valid),
    {
      ...valid,
      get leftTrigger() {
        throw new Error("getter must not execute");
      },
    },
  ]) {
    expect(() => decodeGamepadState(value)).toThrow();
  }
});

test("decoded state has independent immutable ownership", () => {
  const source = { ...neutralGamepadState(), buttons: ["south"] };
  const decoded = decodeGamepadState(source);
  source.buttons.push("north");
  source.leftStickX = 0.5;
  expect(decoded.buttons).toEqual(["south"]);
  expect(decoded.leftStickX).toBe(0);
  expect(Object.isFrozen(decoded)).toBe(true);
  expect(Object.isFrozen(decoded.buttons)).toBe(true);
});

test("signed axis ties match Swift/Rust rounding away from zero", () => {
  const bytes = encodeGamepadReport({
    ...neutralGamepadState(),
    leftStickX: -0.5 / 32768,
    rightStickX: 0.5 / 32767,
  });
  const view = new DataView(bytes.buffer);
  expect(view.getInt16(6, true)).toBe(-1);
  expect(view.getInt16(10, true)).toBe(1);
});
