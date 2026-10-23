import { expectError } from "./helpers/rejection.ts";
import { test, expect } from "bun:test";
import { createServer } from "node:net";
import { decodeServiceStatus } from "@thumble/client";
import { request, type Endpoint } from "@thumble/client/local";
const snapshot = {
  backend: "recording",
  inputEnabled: false,
  active: false,
  generation: "0",
  revision: "0",
  profileId: null,
  sequence: null,
  reportHex: "0014000000000000000000000000000000000000",
  lastReleaseReason: "startup",
};
test("typed local client handles repeated success and rejection without leaking connections", async () => {
  const result = {
    service: {
      instanceId: "test",
      pid: 1,
      configuration: "ephemeral-runtime-only",
    },
    receiver: { pid: 2, snapshot },
    permissions: "not-evaluated",
    deviceRecognition: "not-evaluated",
    phone: "not-evaluated",
  };
  expect(() =>
    decodeServiceStatus({ ...result, phone: "not-connected" }),
  ).toThrow("invalid_service_response");
  expect(() => decodeServiceStatus({ ...result, phone: "connected" })).toThrow(
    "invalid_service_response",
  );
  const server = createServer((socket) => {
    socket.on("error", () => {});
    socket.on("data", (data) => {
      const envelope = JSON.parse(data.toString());
      socket.end(
        JSON.stringify(
          envelope.body.command === "release"
            ? {
                version: 1,
                requestId: envelope.requestId,
                ok: false,
                error: "test_rejection",
              }
            : { version: 1, requestId: envelope.requestId, ok: true, result },
        ) + "\n",
      );
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("bind_failed");
  const endpoint: Endpoint = {
    version: 1,
    instanceId: "test",
    servicePid: 1,
    receiverPid: 2,
    port: address.port,
    token: "0".repeat(64),
    recordingLog: "unused",
  };
  try {
    for (let n = 0; n < 30; n++) {
      const status = await request(endpoint, { command: "status" });
      expect(status.receiver.snapshot.active).toBe(false);
      expect(status.phone).toBe("not-evaluated");
      await expectError(
        request(endpoint, { command: "release" }),
        "test_rejection",
      );
    }
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});
