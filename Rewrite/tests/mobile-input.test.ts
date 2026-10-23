import { expect, test } from "bun:test";
import fixture from "../packages/fixtures/mobile-input-v1.json";
import {
  decodeControlMap,
  decodePracticeAdmission,
  decodeConnectionAdmission,
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

test("native connection admission accepts only metadata and exact live receipts", () => {
  const ready = {
    version: 1,
    status: "ready",
    generation: "7",
    revision: "4",
    practice: false,
    connected: true,
  } as const;
  expect(decodeConnectionAdmission(ready)).toEqual(ready);
  for (const status of [
    "waiting",
    "pairing",
    "connecting",
    "cancelled",
    "unavailable",
    "disconnected",
  ] as const) {
    expect(decodeConnectionAdmission({ version: 1, status })).toEqual({
      version: 1,
      status,
    });
    expect(() =>
      decodeConnectionAdmission({ version: 1, status, secret: "not-allowed" }),
    ).toThrow();
  }
  for (const change of [
    { version: 2 },
    { generation: "0" },
    { generation: "01" },
    { revision: 4 },
    { practice: true },
    { connected: false },
    { secret: "not-allowed" },
  ])
    expect(() => decodeConnectionAdmission({ ...ready, ...change })).toThrow();
  let invoked = false;
  expect(() =>
    decodeConnectionAdmission({
      version: 1,
      status: {
        toString() {
          invoked = true;
          return "waiting";
        },
      },
    }),
  ).toThrow();
  expect(invoked).toBe(false);
  expect(() =>
    decodeConnectionAdmission({ version: 1, status: "starting" }),
  ).toThrow();
});

test("native maps preserve canonical optional haptics and reject unsafe feedback metadata", () => {
  const feedback = {
    style: "rigid",
    pattern: "buzz",
    intensity: 0.7,
    sharpness: 0.92,
    duration: 0.3,
  } as const;
  const make = (value: unknown) => ({
    ...fixture.map,
    controls: fixture.map.controls.map((control, index) =>
      index === 0 ? { ...control, hapticFeedback: value } : control,
    ),
  });
  const result = decodeControlMap(make(feedback));
  expect(result.controls[0]!.hapticFeedback).toEqual(feedback);
  expect(Object.isFrozen(result.controls[0]!.hapticFeedback)).toBe(true);
  for (const value of [
    null,
    undefined,
    {},
    { ...feedback, extra: true },
    { ...feedback, intensity: NaN },
    { ...feedback, sharpness: Infinity },
    { ...feedback, duration: 0.301 },
    { ...feedback, intensity: true },
    { ...feedback, style: "invalid" },
    { ...feedback, pattern: "invalid" },
  ])
    expect(() => decodeControlMap(make(value))).toThrow();
  expect(
    decodeControlMap(make({ ...feedback, style: "none" })).controls[0]!
      .hapticFeedback,
  ).toEqual({
    ...feedback,
    style: "none",
    pattern: "single",
    intensity: 0,
    sharpness: 0,
  });
});
