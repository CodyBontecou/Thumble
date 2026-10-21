import { expect, test } from "bun:test";
import { createHash, timingSafeEqual } from "node:crypto";
import {
  PairingWindows,
  type PairingPorts,
} from "@thumble/application/pairing";
import {
  decodePairingCommand,
  decodePairingReply,
  PAIRING_WINDOW_MS,
} from "@thumble/contracts/pairing";
function fixture(authority = "authority-A") {
  let now = 1000,
    serial = 0,
    entropyFails = false;
  const digests: string[] = [];
  const ports: PairingPorts = {
    now: () => now,
    nextIdentity: () => `window-${++serial}`,
    randomSecret: () => {
      if (entropyFails) throw new Error("entropy_failed");
      return serial.toString(16).padStart(64, "0");
    },
    digest: (text) => {
      const hash = createHash("sha256").update(text).digest("hex");
      digests.push(hash);
      return hash;
    },
    constantTimeEqual: (a, b) =>
      timingSafeEqual(Buffer.from(a, "hex"), Buffer.from(b, "hex")),
  };
  return {
    windows: new PairingWindows(authority, ports),
    digests,
    time: (value: number) => {
      now = value;
    },
    failEntropy: () => {
      entropyFails = true;
    },
  };
}
test("pairing proof succeeds once; public status and admission receipt omit bootstrap material", () => {
  const { windows } = fixture();
  expect(windows.status().state).toBe("closed");
  const offer = windows.open(),
    before = windows.status();
  expect(before).toEqual({
    state: "open",
    windowId: offer.windowId,
    expiresAt: 121000,
    attemptsRemaining: 5,
    networkEnabled: false,
  });
  expect(JSON.stringify(before)).not.toContain(offer.secret);
  const receipt = windows.admit(offer.windowId, offer.secret);
  expect(receipt).toEqual({
    authorityInstanceId: "authority-A",
    windowId: offer.windowId,
  });
  expect(Object.isFrozen(receipt)).toBe(true);
  expect(JSON.stringify(receipt)).not.toContain(offer.secret);
  expect(windows.status().state).toBe("closed");
  expect(() => windows.admit(offer.windowId, offer.secret)).toThrow(
    "pairing_closed",
  );
});
test("wrong ID and malformed secrets each spend one attempt and exhaust the window", () => {
  const { windows } = fixture();
  const offer = windows.open();
  for (const [id, proof] of [
    ["wrong", offer.secret],
    [offer.windowId, "0".repeat(64)],
    [offer.windowId, "a".repeat(63)],
    [null, offer.secret],
    [offer.windowId, "A".repeat(64)],
  ])
    expect(() => windows.admit(id, proof)).toThrow("pairing_proof_rejected");
  expect(windows.status().state).toBe("closed");
  expect(() => windows.admit(offer.windowId, offer.secret)).toThrow(
    "pairing_closed",
  );
});
test("a valid final allowed proof succeeds without granting another attempt", () => {
  const { windows } = fixture();
  const offer = windows.open();
  for (let n = 0; n < 4; n++)
    expect(() => windows.admit(offer.windowId, "f".repeat(64))).toThrow(
      "pairing_proof_rejected",
    );
  expect(windows.status().attemptsRemaining).toBe(1);
  windows.admit(offer.windowId, offer.secret);
  expect(windows.status().attemptsRemaining).toBe(0);
});
test("expiry boundary, replacement, cancellation, restart and entropy failure retire old material", () => {
  const f = fixture();
  const first = f.windows.open();
  f.time(1000 + PAIRING_WINDOW_MS - 1);
  expect(f.windows.status().state).toBe("open");
  f.time(1000 + PAIRING_WINDOW_MS);
  expect(() => f.windows.admit(first.windowId, first.secret)).toThrow(
    "pairing_closed",
  );
  const second = f.windows.open(),
    third = f.windows.open();
  expect(() => f.windows.admit(second.windowId, second.secret)).toThrow(
    "pairing_proof_rejected",
  );
  f.windows.cancel();
  expect(() => f.windows.admit(third.windowId, third.secret)).toThrow(
    "pairing_closed",
  );
  const fourth = f.windows.open();
  f.failEntropy();
  expect(() => f.windows.open()).toThrow("entropy_failed");
  expect(() => f.windows.admit(fourth.windowId, fourth.secret)).toThrow(
    "pairing_closed",
  );
  expect(fixture().windows.status().state).toBe("closed");
});
test("clock rollback and invalid clocks fail closed rather than extending pairing", () => {
  for (const invalid of [
    999,
    NaN,
    Infinity,
    -1,
    1.5,
    Number.MAX_SAFE_INTEGER,
  ]) {
    const f = fixture(),
      offer = f.windows.open();
    f.time(invalid);
    expect(() => f.windows.admit(offer.windowId, offer.secret)).toThrow(
      "pairing_clock_invalid",
    );
    f.time(1000);
    expect(f.windows.status().state).toBe("closed");
  }
});
test("authority and window identities domain-separate the stored verifier", () => {
  const a = fixture("authority-A"),
    b = fixture("authority-B");
  const ao = a.windows.open(),
    bo = b.windows.open();
  expect(ao.secret).toBe(bo.secret);
  expect(ao.windowId).toBe(bo.windowId);
  expect(a.digests[0]).not.toBe(b.digests[0]);
  a.windows.open();
  expect(a.digests[1]).not.toBe(a.digests[0]);
});
test("pairing decoders reject extra fields, inconsistent state, malformed values and accessors", () => {
  const f = fixture(),
    offer = f.windows.open();
  const reply = {
    authorityInstanceId: "authority-A",
    pairing: f.windows.status(),
    offer,
  };
  expect(decodePairingReply(reply)).toEqual(reply);
  expect(Object.isFrozen(decodePairingReply(reply).pairing)).toBe(true);
  for (const invalid of [
    { ...reply, offer: { ...offer, secret: "123456" } },
    { ...reply, offer: { ...offer, windowId: "wrong" } },
    { ...reply, pairing: { ...reply.pairing, attemptsRemaining: 6 } },
    { ...reply, pairing: { ...reply.pairing, networkEnabled: true } },
    { ...reply, pairing: { ...reply.pairing, expiresAt: 1.5 } },
    {
      ...reply,
      pairing: {
        state: "closed",
        windowId: null,
        expiresAt: null,
        attemptsRemaining: 0,
        networkEnabled: false,
      },
    },
    { ...reply, secret: offer.secret },
  ])
    expect(() => decodePairingReply(invalid)).toThrow();
  let reads = 0;
  expect(() =>
    decodePairingCommand({
      get command() {
        reads++;
        return "pairing-open";
      },
    }),
  ).toThrow();
  expect(reads).toBe(0);
  expect(() => decodePairingCommand({ command: "pairing-admit" })).toThrow(
    "unsupported_pairing_command",
  );
  expect(() =>
    decodePairingCommand({ command: "pairing-open", extra: true }),
  ).toThrow();
});

test("portable pairing client refuses a different authority and secret-bearing status replies", async () => {
  const { PairingClient } = await import("@thumble/client/pairing");
  const { expectError } = await import("./helpers/rejection.ts");
  const f = fixture(),
    offer = f.windows.open();
  const reply = {
    authorityInstanceId: "authority-A",
    pairing: f.windows.status(),
    offer,
  };
  const success = new PairingClient("authority-A", { send: async () => reply });
  expect((await success.request({ command: "pairing-open" })).offer).toEqual(
    offer,
  );
  await expectError(
    success.request({ command: "pairing-status" }),
    "pairing_authority_mismatch",
  );
  const wrong = new PairingClient("authority-B", { send: async () => reply });
  await expectError(
    wrong.request({ command: "pairing-open" }),
    "pairing_authority_mismatch",
  );
  const missing = new PairingClient("authority-A", {
    send: async () => ({ ...reply, offer: null }),
  });
  await expectError(
    missing.request({ command: "pairing-open" }),
    "pairing_authority_mismatch",
  );
});

test("shared native enrollment fixture preserves service proof and public status semantics", async () => {
  const f = await Bun.file(
    new URL("../packages/fixtures/enrollment-v1.json", import.meta.url),
  ).json();
  const windows = new PairingWindows(f.authorityInstanceId, {
    now: () => f.openedAt,
    nextIdentity: () => f.offer.windowId,
    randomSecret: () => f.offer.secret,
    digest: (text) => {
      const hash = createHash("sha256").update(text).digest("hex");
      expect(hash).toBe(f.windowVerifier);
      return hash;
    },
    constantTimeEqual: (a, b) =>
      timingSafeEqual(Buffer.from(a, "hex"), Buffer.from(b, "hex")),
  });
  expect(windows.open()).toEqual(f.offer);
  expect(windows.status()).toEqual({
    state: "open",
    windowId: f.offer.windowId,
    expiresAt: f.offer.expiresAt,
    attemptsRemaining: 5,
    networkEnabled: false,
  });
  expect(windows.admit(f.enroll.windowId, f.enroll.proof)).toEqual({
    authorityInstanceId: f.authorityInstanceId,
    windowId: f.offer.windowId,
  });
  expect(windows.status()).toEqual({
    state: "closed",
    windowId: null,
    expiresAt: null,
    attemptsRemaining: 0,
    networkEnabled: false,
  });
});
