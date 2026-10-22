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
  type PairingCommand,
  type PairingTransport,
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

test("listener commands require bounded explicit addresses without executing caller objects", () => {
  const value = {
    command: "pairing-listen",
    bindAddress: "127.0.0.1:0",
    advertiseHost: "127.0.0.1",
  } satisfies PairingCommand;
  expect(decodePairingCommand(value)).toEqual(value);
  expect(Object.isFrozen(decodePairingCommand(value))).toBe(true);
  for (const bad of [
    { ...value, bindAddress: "localhost:0" },
    { ...value, advertiseHost: "0.0.0.0" },
    { ...value, advertiseHost: "127.0.0.1/path" },
    { ...value, secret: "not-an-option" },
    { command: "pairing-stop-listening", bindAddress: "127.0.0.1:0" },
  ])
    expect(() => decodePairingCommand(bad)).toThrow();
  let calls = 0;
  expect(() =>
    decodePairingCommand({
      get command() {
        calls++;
        return "pairing-listen";
      },
      bindAddress: "127.0.0.1:0",
      advertiseHost: "127.0.0.1",
    }),
  ).toThrow();
  expect(() =>
    decodePairingCommand({
      command: {
        toString() {
          calls++;
          return "pairing-open";
        },
      },
    }),
  ).toThrow();
  expect(calls).toBe(0);
});
test("native listener metadata binds full invitations to the exact advertised host pin port and authority", () => {
  const f = fixture(),
    offer = f.windows.open();
  const transport = {
    listening: true,
    bindAddress: "127.0.0.1:12345",
    advertiseHost: "127.0.0.1",
    port: 12345,
    certificatePin: "1".repeat(64),
    certificateDER: "00",
    persistentIdentity: true,
    serverName: "thumble-rewrite.local",
    controlVersion: 2,
    inputEnabled: false,
  } satisfies PairingTransport;
  const reply = {
    authorityInstanceId: "authority-A",
    pairing: { ...f.windows.status(), networkEnabled: true },
    offer: {
      ...offer,
      host: "127.0.0.1",
      port: 12345,
      certificatePin: transport.certificatePin,
      authorityInstanceId: "authority-A",
    },
    transport,
  };
  expect(decodePairingReply(reply)).toEqual(reply);
  expect(Object.isFrozen(decodePairingReply(reply).transport)).toBe(true);
  for (const invalid of [
    { ...reply, offer: { ...reply.offer, host: "different.local" } },
    { ...reply, offer: { ...reply.offer, port: 12346 } },
    { ...reply, offer: { ...reply.offer, certificatePin: "2".repeat(64) } },
    {
      ...reply,
      offer: { ...reply.offer, authorityInstanceId: "another-authority" },
    },
    { ...reply, transport: { ...transport, inputEnabled: true } },
    { ...reply, transport: { ...transport, persistentIdentity: false } },
    { ...reply, transport: { ...transport, certificateDER: "GG" } },
    { ...reply, transport: { ...transport, serverName: "wrong.local" } },
    { ...reply, transport: { ...transport, port: "12345" } },
    { ...reply, pairing: { ...reply.pairing, networkEnabled: false } },
  ])
    expect(() => decodePairingReply(invalid)).toThrow();
});

test("trusted inventory exposes bounded immutable metadata and rejects executable or secret fields", () => {
  const f = fixture();
  const phone = {
    phoneId: "phone-a",
    label: "Controller",
    credentialEpoch: "1",
    active: true,
    expiresAt: 123456,
  };
  const base = {
    authorityInstanceId: "authority-A",
    pairing: f.windows.status(),
    offer: null,
  };
  const reply = decodePairingReply({ ...base, phones: [phone] });
  expect(reply.phones).toEqual([phone]);
  expect(Object.isFrozen(reply.phones)).toBe(true);
  expect(Object.isFrozen(reply.phones![0])).toBe(true);
  expect(decodePairingCommand({ command: "pairing-list" })).toEqual({
    command: "pairing-list",
  });
  expect(
    decodePairingCommand({ command: "pairing-revoke", phoneId: "phone-a" }),
  ).toEqual({ command: "pairing-revoke", phoneId: "phone-a" });
  for (const phones of [
    [{ ...phone, credential: "secret" }],
    [phone, phone],
    [{ ...phone, credentialEpoch: "01" }],
    [{ ...phone, credentialEpoch: "9223372036854775808" }],
    [{ ...phone, label: "é".repeat(65) }],
    [{ ...phone, label: "bad\nlabel" }],
    [{ ...phone, active: 1 }],
    [{ ...phone, expiresAt: 0 }],
    Array(1),
    Array(33).fill(phone),
  ])
    expect(() => decodePairingReply({ ...base, phones })).toThrow();
  let calls = 0;
  const phones = [phone];
  Object.defineProperty(phones, "0", {
    get() {
      calls++;
      return phone;
    },
  });
  expect(() => decodePairingReply({ ...base, phones })).toThrow();
  expect(() =>
    decodePairingCommand({
      command: "pairing-revoke",
      get phoneId() {
        calls++;
        return "phone-a";
      },
    }),
  ).toThrow();
  expect(calls).toBe(0);
  expect(() => decodePairingCommand({ command: "pairing-revoke" })).toThrow();
  expect(() =>
    decodePairingCommand({ command: "pairing-open", phoneId: "phone-a" }),
  ).toThrow();
});

test("native invitation intake fixtures use the existing canonical CLI offer", async () => {
  const fixture = await Bun.file(
    new URL("../packages/fixtures/pairing-invitation-v1.json", import.meta.url),
  ).json();
  for (const offer of fixture.valid) {
    const reply = decodePairingReply({
      authorityInstanceId: offer.authorityInstanceId,
      pairing: {
        state: "open",
        windowId: offer.windowId,
        expiresAt: offer.expiresAt,
        attemptsRemaining: 5,
        networkEnabled: true,
      },
      offer,
      transport: {
        listening: true,
        bindAddress: `127.0.0.1:${offer.port}`,
        advertiseHost: offer.host,
        port: offer.port,
        certificatePin: offer.certificatePin,
        certificateDER: "00",
        persistentIdentity: true,
        serverName: "thumble-rewrite.local",
        controlVersion: 2,
        inputEnabled: false,
      },
    });
    expect(reply.offer).toEqual(offer);
    expect(Object.isFrozen(reply.offer)).toBe(true);
    expect(
      new TextEncoder().encode(JSON.stringify(reply.offer)).byteLength,
    ).toBeLessThanOrEqual(4096);
  }
});
