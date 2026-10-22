import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { WowCaptureSession } from "../apps/service/src/wow-capture-session.ts";
import { decodeWowAtlas } from "../apps/service/src/wow-atlas-decoder.ts";
import { atlasPNGFixture } from "./fixtures/wow-atlas-fixture.ts";
import {
  decodeWowCaptureCommand,
  decodeWowCaptureControlStatus,
  disabledWowCaptureStatus,
} from "@thumble/contracts/wow-capture-control";
const frame = JSON.parse(
  readFileSync(
    resolve(import.meta.dir, "../packages/fixtures/wow-live-v1.json"),
    "utf8",
  ),
).frames[0] as string;
test("capture session exposes verified same-receipt metadata only and retires it on request, stop, age and source changes", async () => {
  let now = 0,
    stops = 0;
  const session = new WowCaptureSession({
    clock: () => now,
    schedule: () => () => {},
    decodeAtlas: decodeWowAtlas,
    create: () => ({
      capture: async (text) => {
        const request = JSON.parse(text);
        return JSON.stringify({
          ...request,
          command: "wow-capture-result",
          kind: "frame",
          frameBase64: Buffer.from(frame, "hex").toString("base64"),
          atlasPNGBase64: atlasPNGFixture().toString("base64"),
        });
      },
      stop: async () => {
        stops++;
      },
    }),
  });
  expect(session.status().state).toBe("stopped");
  await session.execute({
    command: "wow-capture-start",
    source: "world-of-warcraft",
  });
  await new Promise((resolve) => setImmediate(resolve));
  const ready = decodeWowCaptureControlStatus(session.status());
  expect(ready.state).toBe("ready");
  expect(ready.receipt?.kind).toBe("frame");
  expect(JSON.stringify(ready)).not.toContain("Base64");
  expect(JSON.stringify(ready)).not.toContain(frame);
  now = 2000;
  expect(session.status().receipt).toBeNull();
  await session.execute({
    command: "wow-capture-start",
    source: "world-of-warcraft",
  });
  await new Promise((resolve) => setImmediate(resolve));
  expect(session.status().source).toBe(2);
  expect(session.status().generation).toBe("2");
  session.providerUnavailable();
  expect(session.status().state).toBe("unavailable");
  expect(session.status().receipt).toBeNull();
  await session.execute({ command: "wow-capture-stop" });
  expect(session.status().state).toBe("stopped");
  expect(session.status().receipt).toBeNull();
  expect(stops).toBe(2);
});
test("capture local API rejects window/path injection, invalid metadata, getters and permission claims", () => {
  expect(
    decodeWowCaptureControlStatus(disabledWowCaptureStatus()).enabled,
  ).toBe(false);
  for (const value of [
    { command: "wow-capture-start", source: "window:42" },
    { command: "wow-capture-status", path: "secret" },
    {
      command: "wow-capture-start",
      source: "world-of-warcraft",
      helper: "arbitrary",
    },
  ])
    expect(() => decodeWowCaptureCommand(value)).toThrow();
  const status = disabledWowCaptureStatus();
  for (const patch of [
    { state: "ready" },
    { source: 1 },
    { permission: "authorized" },
    { receipt: { kind: "frame" } },
  ])
    expect(() =>
      decodeWowCaptureControlStatus({ ...status, ...patch }),
    ).toThrow();
  const poisoned = JSON.parse(
    JSON.stringify(status).slice(0, -1) + ',"__proto__":{}}',
  );
  expect(() => decodeWowCaptureControlStatus(poisoned)).toThrow();
  let reads = 0;
  const getter = Object.defineProperty({ ...status }, "state", {
    get() {
      reads++;
      return "disabled";
    },
  });
  expect(() => decodeWowCaptureControlStatus(getter)).toThrow();
  expect(reads).toBe(0);
});
