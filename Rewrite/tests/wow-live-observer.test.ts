import { expect, test } from "bun:test";
import { WowLiveObserver } from "@thumble/application/wow-live-observer";
import { wowLiveChecksum } from "@thumble/domain/wow-live";

// Synthetic protocol data, not a captured game or account export.
function fixture(
  name = "Synthetic",
  id = "Player-Synthetic-001",
  flavor = "classic-era",
) {
  return {
    schema: "thumble.wow-live",
    version: 1,
    client: { flavor, interface: flavor === "classic-era" ? 11509 : 16001 },
    character: { id, name, realm: "Fixture", classTag: "MAGE" },
    actions: [],
    icons: [],
    devices: [],
    consolePortVersion: "absent",
  };
}
function seal(bytes: Uint8Array) {
  const view = new DataView(bytes.buffer);
  const data = new Uint8Array(21 + view.getUint16(17, true));
  data.set(bytes.subarray(0, 21));
  data.set(bytes.subarray(25, 25 + data.length - 21), 21);
  view.setUint32(21, wowLiveChecksum(data), true);
  return bytes;
}
function pages(value: unknown, tick = 1) {
  const message = new TextEncoder().encode(JSON.stringify(value));
  return Array.from({ length: Math.ceil(message.length / 487) }, (_, page) => {
    const bytes = new Uint8Array(512),
      view = new DataView(bytes.buffer);
    const payload = message.subarray(page * 487, (page + 1) * 487);
    bytes.set([84, 72, 87, 76, 1]);
    view.setUint32(5, (tick + page) >>> 0, true);
    view.setUint32(9, wowLiveChecksum(message), true);
    view.setUint16(13, page, true);
    view.setUint16(15, Math.ceil(message.length / 487), true);
    view.setUint16(17, payload.length, true);
    view.setUint16(19, message.length, true);
    bytes.set(payload, 25);
    return seal(bytes);
  });
}
function retick(bytes: Uint8Array, tick: number) {
  const result = bytes.slice();
  new DataView(result.buffer).setUint32(5, tick, true);
  return seal(result);
}
function stage(
  observer: WowLiveObserver,
  value = fixture(),
  tick = 1,
  now = 0,
  source = 42,
  generation = "1",
) {
  const frame = pages(value, tick)[0]!;
  observer.observe(source, generation, frame, now);
  return observer.observe(
    source,
    generation,
    retick(frame, tick + 1),
    now + 10,
  )!;
}
test("pending snapshot is immutable, bounded identity; failed/conflicting commits preserve intent until successful ACK", () => {
  const observer = new WowLiveObserver(),
    intent = stage(observer);
  expect(intent).toMatchObject({
    receipt: "1",
    source: 42,
    generation: "1",
    tick: 2,
    select: true,
    character: { flavor: "classic-era", id: "Player-Synthetic-001" },
  });
  expect(Object.isFrozen(intent)).toBe(true);
  expect(Object.isFrozen(intent.character)).toBe(true);
  expect(Object.isFrozen(intent.snapshot.character)).toBe(true);
  expect(observer.acknowledge(intent, { kind: "conflict" }, 20)).toBe(false);
  expect(observer.pending(30)).toBe(intent);
  expect(observer.acknowledge(intent, { kind: "failed" }, 40)).toBe(false);
  expect(observer.pending(50)).toBe(intent);
  for (const identity of [
    { ...intent, receipt: "2" },
    { ...intent, source: 43 },
    { ...intent, generation: "2" },
  ])
    expect(observer.acknowledge(identity, { kind: "committed" }, 60)).toBe(
      false,
    );
  expect(observer.acknowledge(intent, { kind: "committed" }, 70)).toBe(true);
  expect(observer.pending(80)).toBeUndefined();
  expect(observer.acknowledge(intent, { kind: "committed" }, 90)).toBe(false);
  expect(observer.isLive(100)).toBe(true);
});
test("selection intent tracks last committed character and flavor, never mere observation or changed display name", () => {
  const observer = new WowLiveObserver(),
    first = stage(observer);
  const changedBeforeCommit = stage(
    observer,
    fixture("Uncommitted rename"),
    3,
    20,
  );
  expect(changedBeforeCommit.select).toBe(true);
  expect(observer.acknowledge(first, { kind: "committed" }, 40)).toBe(false);
  expect(
    observer.acknowledge(changedBeforeCommit, { kind: "committed" }, 50),
  ).toBe(true);
  const rename = stage(observer, fixture("Committed rename"), 5, 60);
  expect(rename.select).toBe(false);
  expect(observer.acknowledge(rename, { kind: "committed" }, 80)).toBe(true);
  const other = stage(
    observer,
    fixture("Other", "Player-Synthetic-002"),
    7,
    90,
  );
  expect(other.select).toBe(true);
  expect(observer.acknowledge(other, { kind: "committed" }, 110)).toBe(true);
  const original = stage(observer, fixture(), 9, 120);
  expect(original.select).toBe(true);
  expect(observer.acknowledge(original, { kind: "committed" }, 140)).toBe(true);
  expect(
    stage(
      observer,
      fixture("Synthetic", "Player-Synthetic-001", "forever"),
      11,
      150,
    ).select,
  ).toBe(true);
});
test("new partial message supersedes old pending immediately; replayed/backward partial cannot do so", () => {
  const observer = new WowLiveObserver(),
    old = stage(observer);
  const many = {
    ...fixture(),
    devices: Array.from({ length: 16 }, (_, i) => ({
      name: `Synthetic${i}`.padEnd(128, "x"),
      vendorID: null,
      productID: null,
    })),
  };
  const frames = pages(many, 3);
  expect(frames.length).toBeGreaterThan(2);
  observer.observe(42, "1", retick(frames[0]!, 2), 20);
  expect(observer.pending(20)).toBe(old);
  observer.observe(42, "1", retick(frames[0]!, 1), 30);
  expect(observer.pending(30)).toBe(old);
  observer.observe(42, "1", frames[0]!, 40);
  expect(observer.pending(40)).toBeUndefined();
  expect(observer.acknowledge(old, { kind: "committed" }, 50)).toBe(false);
  for (let i = 1; i < frames.length; i++)
    observer.observe(42, "1", frames[i]!, 50 + i);
  const current = observer.pending(100)!;
  expect(current.receipt).toBe("2");
  expect(current.snapshot.devices.length).toBe(16);
});
test("source and generation changes require new liveness and reject late captures without restoring old intent", () => {
  const observer = new WowLiveObserver(),
    old = stage(observer);
  const frame = pages(fixture(), 1)[0]!;
  expect(observer.observe(43, "2", frame, 20)).toBeUndefined();
  expect(observer.pending(20)).toBeUndefined();
  expect(observer.isLive(20)).toBe(false);
  expect(observer.acknowledge(old, { kind: "committed" }, 20)).toBe(false);
  const next = observer.observe(43, "2", retick(frame, 2), 30)!;
  expect(next.generation).toBe("2");
  expect(next.source).toBe(43);
  expect(() => observer.observe(42, "1", retick(frame, 3), 40)).toThrow(
    "wow_observer_context_mismatch",
  );
  expect(() => observer.observe(42, "2", retick(frame, 3), 40)).toThrow(
    "wow_observer_context_mismatch",
  );
  expect(observer.pending(40)).toBe(next);
  expect(observer.observe(43, "3", frame, 50)).toBeUndefined();
  expect(observer.pending(50)).toBeUndefined();
  expect(observer.acknowledge(next, { kind: "committed" }, 50)).toBe(false);
});
test("expiry, frozen replay and time high-water prevent late ACK or revival; advancing transport stays separate", () => {
  const observer = new WowLiveObserver(),
    old = stage(observer);
  const frame = pages(fixture(), 1)[0]!;
  observer.observe(42, "1", retick(frame, 2), 1500);
  expect(observer.pending(2009)).toBe(old);
  expect(observer.pending(2010)).toBeUndefined();
  expect(observer.acknowledge(old, { kind: "committed" }, 2010)).toBe(false);
  expect(observer.pending(100)).toBeUndefined();
  expect(observer.isLive(100)).toBe(false);
  expect(() => observer.observe(42, "1", retick(frame, 3), 2009)).toThrow(
    "invalid_wow_observer_time",
  );
  expect(observer.observe(42, "1", frame, 2011)).toBeUndefined();
  const current = observer.observe(42, "1", retick(frame, 2), 2012)!;
  expect(current.receipt).toBe("2");
  expect(observer.acknowledge(current, { kind: "failed" }, 4012)).toBe(false);
  expect(observer.pending(4012)).toBeUndefined();
});
test("malformed pages and unsupported newer snapshots clear older pending without schema coercion", () => {
  const observer = new WowLiveObserver(),
    old = stage(observer);
  const malformed = pages(fixture(), 3)[0]!;
  malformed[100] = malformed[100]! ^ 1;
  expect(() => observer.observe(42, "1", malformed, 20)).toThrow();
  expect(observer.pending(20)).toBeUndefined();
  expect(observer.acknowledge(old, { kind: "committed" }, 20)).toBe(false);
  const newer = pages({ ...fixture(), version: 2 }, 3)[0]!;
  expect(() => observer.observe(42, "1", newer, 30)).toThrow(
    "invalid_wow_live_snapshot",
  );
  expect(observer.pending(30)).toBeUndefined();
  expect(observer.isLive(30)).toBe(true);
});
test("identity/time bounds and exhausted nonwrapping receipts fail closed", () => {
  for (const seed of ["-1", "01", "18446744073709551616", "1e3"])
    expect(() => new WowLiveObserver(seed)).toThrow(
      "invalid_wow_observer_identity",
    );
  const frame = pages(fixture())[0]!;
  for (const generation of ["0", "-1", "01", "18446744073709551616"])
    expect(() =>
      new WowLiveObserver().observe(42, generation, frame, 0),
    ).toThrow("invalid_wow_observer_identity");
  for (const source of [0, -1, 4294967296, 0.5, NaN])
    expect(() => new WowLiveObserver().observe(source, "1", frame, 0)).toThrow(
      "invalid_wow_observer_identity",
    );
  for (const now of [-1, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1])
    expect(() => new WowLiveObserver().observe(42, "1", frame, now)).toThrow(
      "invalid_wow_observer_time",
    );
  const observer = new WowLiveObserver("18446744073709551614");
  const last = stage(observer);
  expect(last.receipt).toBe("18446744073709551615");
  expect(() => stage(observer, fixture("New"), 3, 20)).toThrow(
    "wow_observer_receipt_exhausted",
  );
  expect(observer.pending(40)).toBeUndefined();
  expect(observer.acknowledge(last, { kind: "committed" }, 40)).toBe(false);
  expect(() => stage(observer, fixture("Newer"), 5, 50)).toThrow(
    "wow_observer_receipt_exhausted",
  );
  expect(observer.pending(70)).toBeUndefined();
});

test("uint32 tick wrap and unchanged advancing payload refresh transport without restaging a receipt", () => {
  const observer = new WowLiveObserver();
  const intent = stage(
    observer,
    fixture(),
    4294967295,
    0,
    4294967295,
    "18446744073709551615",
  );
  expect(intent.tick).toBe(0);
  expect(intent.source).toBe(4294967295);
  expect(intent.generation).toBe("18446744073709551615");
  const frame = pages(fixture())[0]!;
  observer.observe(
    4294967295,
    "18446744073709551615",
    retick(frame, 2147483648),
    20,
  );
  expect(observer.pending(20)).toBe(intent);
  observer.observe(4294967295, "18446744073709551615", retick(frame, 1), 1000);
  expect(observer.pending(2999)).toBe(intent);
  expect(observer.acknowledge(intent, { kind: "committed" }, 2999)).toBe(true);
  observer.observe(4294967295, "18446744073709551615", retick(frame, 2), 2999);
  expect(observer.isLive(2999)).toBe(true);
  expect(observer.pending(2999)).toBeUndefined();
});

test("backward acknowledgement cannot consume or revive a currently live intent", () => {
  const observer = new WowLiveObserver(),
    intent = stage(observer);
  expect(observer.pending(100)).toBe(intent);
  expect(observer.acknowledge(intent, { kind: "committed" }, 99)).toBe(false);
  expect(observer.pending(101)).toBeUndefined();
  expect(observer.isLive(101)).toBe(true);
  expect(observer.acknowledge(intent, { kind: "committed" }, 102)).toBe(false);
});

test("malformed page cannot restore old intent; valid continuation may complete the new bounded message", () => {
  const observer = new WowLiveObserver(),
    old = stage(observer);
  const many = {
    ...fixture(),
    devices: Array.from({ length: 16 }, (_, i) => ({
      name: `Synthetic${i}`.padEnd(128, "x"),
      vendorID: null,
      productID: null,
    })),
  };
  const frames = pages(many, 3);
  observer.observe(42, "1", frames[0]!, 20);
  const bad = frames[1]!.slice();
  bad[100] = bad[100]! ^ 1;
  expect(() => observer.observe(42, "1", bad, 30)).toThrow();
  expect(observer.pending(30)).toBeUndefined();
  expect(observer.acknowledge(old, { kind: "committed" }, 30)).toBe(false);
  for (let i = 1; i < frames.length; i++)
    observer.observe(42, "1", frames[i]!, 40 + i);
  const next = observer.pending(100)!;
  expect(next.receipt).toBe("2");
  expect(next.snapshot.devices.length).toBe(16);
  const malformed = frames[0]!.slice();
  malformed[100] = malformed[100]! ^ 1;
  expect(() => observer.observe(42, "1", malformed, 110)).toThrow();
  observer.observe(42, "1", retick(frames[0]!, 20), 120);
  expect(observer.isLive(120)).toBe(true);
  expect(observer.pending(120)).toBeUndefined();
});
