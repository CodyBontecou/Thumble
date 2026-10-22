import { expect, test } from "bun:test";
import fixture from "../packages/fixtures/mobile-input-v1.json";
import {
  decodeControlMap,
  decodePracticeAdmission,
} from "@thumble/contracts/mobile-input";
import { decodeGamepadState } from "@thumble/contracts";
import { encodeGamepadReport } from "@thumble/domain";
test("mobile control maps are bounded, immutable and share native semantic fixtures", () => {
  const map = decodeControlMap(fixture.map);
  expect(Object.isFrozen(map.controls[0])).toBe(true);
  expect(Object.isFrozen(map.controls)).toBe(true);
  for (const scenario of fixture.scenarios) {
    if ("controls" in scenario)
      decodeControlMap({ ...fixture.map, controls: scenario.controls });
    for (const event of scenario.events) {
      const state = decodeGamepadState(event.expected.state);
      expect(Buffer.from(encodeGamepadReport(state)).toString("hex")).toBe(
        event.expected.reportHex,
      );
    }
  }
});
test("invalid native maps cannot be admitted through the JS configuration boundary", () => {
  for (const value of [
    { ...fixture.map, generation: "0" },
    { ...fixture.map, generation: "18446744073709551616" },
    { ...fixture.map, revision: "01" },
    { ...fixture.map, extra: true },
    { ...fixture.map, controls: [] },
    { ...fixture.map, controls: Array(65).fill(fixture.map.controls[0]) },
    {
      ...fixture.map,
      controls: [fixture.map.controls[0], fixture.map.controls[0]],
    },
    ...[
      { x: NaN },
      { width: 0 },
      { width: 2 },
      { action: "javascriptCallback" },
      { extra: true },
    ].map((change) => ({
      ...fixture.map,
      controls: [{ ...fixture.map.controls[0], ...change }],
    })),
  ])
    expect(() => decodeControlMap(value)).toThrow();
});
test("mobile map getters cannot execute and source mutation cannot edit an admitted map", () => {
  let reads = 0;
  const hostile = { ...fixture.map };
  Object.defineProperty(hostile, "generation", {
    get() {
      reads++;
      return "1";
    },
    enumerable: true,
  });
  expect(() => decodeControlMap(hostile)).toThrow();
  expect(reads).toBe(0);
  const source = structuredClone(fixture.map);
  const map = decodeControlMap(source);
  source.controls[0]!.action = "south";
  source.controls.length = 0;
  expect(map.controls.length).toBe(6);
  expect(map.controls[0]!.action).toBe("leftStick");
});

test("native bridge configuration requires the matching activation receipt", async () => {
  const { MobileInputClient } = await import("@thumble/client/mobile-input");
  const { expectError } = await import("./helpers/rejection.ts");
  const { neutralGamepadState } = await import("@thumble/contracts");
  let wrong = false;
  const client = new MobileInputClient({
    async configure(map) {
      return {
        version: 1,
        generation: wrong ? "2" : map.generation,
        revision: map.revision,
      };
    },
    async setPractice() {},
    async release() {},
    async snapshot() {
      return {
        generation: "1",
        connected: false,
        practice: true,
        state: neutralGamepadState(),
        lastRelease: "practice",
      };
    },
  });
  expect((await client.configure(fixture.map)).generation).toBe("1");
  wrong = true;
  await expectError(
    client.configure(fixture.map),
    "native_activation_mismatch",
  );
  expect((await client.snapshot()).practice).toBe(true);
});
test("native control lists reject holes and accessor elements without executing them", () => {
  expect(() =>
    decodeControlMap({ ...fixture.map, controls: new Array(1) }),
  ).toThrow();
  let reads = 0;
  const controls = [fixture.map.controls[0]];
  Object.defineProperty(controls, "0", {
    get() {
      reads++;
      return fixture.map.controls[0];
    },
    enumerable: true,
  });
  expect(() => decodeControlMap({ ...fixture.map, controls })).toThrow();
  expect(reads).toBe(0);
});

test("practice admission requires a native neutral-output receipt and rejects malformed metadata", () => {
  const ready: import("@thumble/contracts/mobile-input").PracticeAdmission = {
    version: 1,
    status: "ready",
    generation: "1",
    revision: "0",
    practice: true,
    connected: false,
  };
  expect(decodePracticeAdmission(ready)).toEqual(ready);
  expect(
    decodePracticeAdmission({ version: 1, status: "unavailable" }),
  ).toEqual({ version: 1, status: "unavailable" });
  for (const change of [
    { generation: "0" },
    { generation: "01" },
    { revision: 0 },
    { practice: false },
    { connected: true },
    { extra: true },
    { status: "starting" },
    { version: 2 },
  ])
    expect(() => decodePracticeAdmission({ ...ready, ...change })).toThrow();
  expect(() =>
    decodePracticeAdmission({
      version: 1,
      status: "unavailable",
      generation: "1",
    }),
  ).toThrow();
});
