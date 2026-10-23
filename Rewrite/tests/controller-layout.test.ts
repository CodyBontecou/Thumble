import { expect, test } from "bun:test";
import { decodeControlMap } from "@thumble/contracts/mobile-input";
import { GAMEPAD_BUTTONS } from "@thumble/contracts";
import { standardControllerMap } from "@thumble/domain/controller-layout";
import fixture from "../packages/fixtures/controller-layout-v1.json";

test("initial landscape map exposes every report control without overlapping hit regions", () => {
  const map = standardControllerMap("18446744073709551615", "9007199254740993");
  expect(map.generation).toBe("18446744073709551615");
  expect(map.revision).toBe("9007199254740993");
  expect(new Set(map.controls.map((c) => c.action))).toEqual(
    new Set([
      ...GAMEPAD_BUTTONS.filter(
        (b) => b !== "leftTriggerButton" && b !== "rightTriggerButton",
      ),
      "leftStick",
      "rightStick",
      "leftTrigger",
      "rightTrigger",
    ]),
  );
  for (let i = 0; i < map.controls.length; i++)
    for (let j = i + 1; j < map.controls.length; j++) {
      const a = map.controls[i]!,
        b = map.controls[j]!;
      expect(
        a.x + a.width <= b.x ||
          b.x + b.width <= a.x ||
          a.y + a.height <= b.y ||
          b.y + b.height <= a.y,
      ).toBe(true);
    }
  expect(Object.isFrozen(map.controls)).toBe(true);
  expect(map.controls.every(Object.isFrozen)).toBe(true);
  expect(standardControllerMap("1", "0")).toEqual(
    decodeControlMap(fixture.map),
  );
});
test("controller epochs remain caller-owned and native fixture probes hit only their intended region", () => {
  for (const args of [
    ["0", "0"],
    ["01", "0"],
    ["1", "-1"],
    ["18446744073709551616", "0"],
  ])
    expect(() => standardControllerMap(args[0]!, args[1]!)).toThrow();
  expect(fixture.probes.length).toBe(19);
  for (const probe of fixture.probes) {
    const hits = fixture.map.controls.filter(
      (c) =>
        probe.x >= c.x &&
        probe.x < c.x + c.width &&
        probe.y >= c.y &&
        probe.y < c.y + c.height,
    );
    expect(hits.map((c) => c.id)).toEqual([probe.id]);
  }
});
