import { expect, test } from "bun:test";
import {
  decodeWowLiveSnapshot,
  WowLiveAssembler,
  wowLiveChecksum,
  type WowLiveSnapshot,
} from "../packages/domain/src/wow-live.ts";
// Entirely synthetic; no retained account/character export or captured pixels.
function fixture() {
  return {
    schema: "thumble.wow-live",
    version: 1,
    client: { flavor: "classic-era", interface: 11509 },
    character: {
      id: "Player-Synthetic-001",
      name: "Test",
      realm: "Fixture",
      classTag: "MAGE",
    },
    actions: [
      {
        bank: "base",
        button: "south",
        command: "ACTIONBUTTON1",
        label: "Synthetic spell".padEnd(128, "x"),
        kind: "spell",
        slot: 1,
        actionID: 123,
        iconFileID: 456,
        iconIndex: 1,
      },
    ],
    icons: [456],
    devices: [{ name: "Synthetic controller", vendorID: 0, productID: 0 }],
    consolePortVersion: "absent",
  } satisfies WowLiveSnapshot;
}
const encode = (value: unknown) =>
  new TextEncoder().encode(JSON.stringify(value));
function seal(bytes: Uint8Array) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength),
    size = view.getUint16(17, true);
  const data = new Uint8Array(21 + size);
  data.set(bytes.subarray(0, 21));
  data.set(bytes.subarray(25, 25 + size), 21);
  view.setUint32(21, wowLiveChecksum(data), true);
  return bytes;
}
function pages(message: Uint8Array, firstTick = 1): Uint8Array[] {
  return Array.from({ length: Math.ceil(message.length / 487) }, (_, page) => {
    const bytes = new Uint8Array(512),
      view = new DataView(bytes.buffer),
      payload = message.subarray(page * 487, (page + 1) * 487);
    bytes.set([84, 72, 87, 76, 1]);
    view.setUint32(5, (firstTick + page) >>> 0, true);
    view.setUint32(9, wowLiveChecksum(message), true);
    view.setUint16(13, page, true);
    view.setUint16(15, Math.ceil(message.length / 487), true);
    view.setUint16(17, payload.length, true);
    view.setUint16(19, message.length, true);
    bytes.set(payload, 25);
    return seal(bytes);
  });
}
function tick(bytes: Uint8Array, value: number): Uint8Array {
  const changed = bytes.slice();
  new DataView(changed.buffer).setUint32(5, value, true);
  return seal(changed);
}
function onePage() {
  return pages(
    encode({ ...fixture(), actions: [], icons: [], devices: [] }),
  )[0]!;
}

test("synthetic retained checksums/pages reassemble immutable observations", () => {
  expect(wowLiveChecksum(new TextEncoder().encode("Wikipedia"))).toBe(
    0x11e60398,
  );
  const assembler = new WowLiveAssembler(),
    frames = pages(encode(fixture()));
  expect(frames.length).toBe(2);
  expect(assembler.observe(42, frames[0]!, 0)).toBeUndefined();
  const snapshot = assembler.observe(42, frames[1]!, 200)!;
  expect(snapshot).toEqual(fixture());
  expect(Object.isFrozen(snapshot.actions[0])).toBe(true);
  expect(assembler.observe(42, tick(frames[0]!, 3), 400)).toBeUndefined();
  expect(assembler.isLive(2399)).toBe(true);
  expect(assembler.isLive(2400)).toBe(false);
});
test("single frozen/replayed pages cannot create or refresh observation liveness", () => {
  const assembler = new WowLiveAssembler(),
    first = onePage();
  for (const now of [0, 100, 1000, 2000, 2100, 4000, 10000]) {
    expect(assembler.observe(42, first, now)).toBeUndefined();
    expect(assembler.isLive(now)).toBe(false);
  }
  expect(assembler.observe(42, tick(first, 2), 10001)).toBeDefined();
  for (const [n, t] of [
    [2, 11000],
    [1, 11500],
    [0x80000002, 11999],
  ])
    expect(assembler.observe(42, tick(first, n!), t!)).toBeUndefined();
  expect(assembler.isLive(12001)).toBe(false);
});
test("uint32 wrap advances; half-range ambiguity is replay", () => {
  const a = new WowLiveAssembler(),
    f = onePage();
  a.observe(1, tick(f, 0xffffffff), 0);
  expect(a.observe(1, tick(f, 0), 1)).toBeDefined();
  expect(a.observe(1, tick(f, 0x80000000), 1000)).toBeUndefined();
  expect(a.isLive(2001)).toBe(false);
});
test("source switches and stale addon reloads require two advancing ticks", () => {
  const a = new WowLiveAssembler(),
    f = onePage();
  a.observe(1, tick(f, 100), 0);
  expect(a.observe(1, tick(f, 101), 1)).toBeDefined();
  expect(a.observe(2, tick(f, 102), 2)).toBeUndefined();
  expect(a.isLive(2)).toBe(false);
  expect(a.observe(2, tick(f, 103), 3)).toBeDefined();
  expect(a.observe(2, tick(f, 1), 2003)).toBeUndefined();
  expect(a.isLive(2003)).toBe(false);
  expect(a.observe(2, tick(f, 2), 2004)).toBeDefined();
});
test("clock regression fails closed; invalid clock/source values are rejected", () => {
  const a = new WowLiveAssembler(),
    f = onePage();
  a.observe(1, f, 10);
  a.observe(1, tick(f, 2), 11);
  expect(a.isLive(9)).toBe(false);
  expect(() => a.observe(1, tick(f, 3), 9)).toThrow();
  expect(a.isLive(12)).toBe(false);
  for (const t of [NaN, Infinity, -1, 1.5, Number.MAX_SAFE_INTEGER + 1])
    expect(() => a.observe(1, f, t)).toThrow();
  for (const s of [0, -1, NaN, 1.5, 4294967296])
    expect(() => a.observe(s, f, 12)).toThrow();
});
test("malformed frame lengths/counts/padding/checksums are rejected", () => {
  const f = onePage();
  for (const offset of [0, 4, 15, 17, 19, 21, 100, 511]) {
    const bad = f.slice();
    bad[offset] = bad[offset]! ^ 255;
    expect(() => new WowLiveAssembler().observe(1, bad, 0)).toThrow();
  }
  for (const length of [0, 511, 513])
    expect(() =>
      new WowLiveAssembler().observe(1, new Uint8Array(length), 0),
    ).toThrow();
  for (const [offset, value] of [
    [13, 2],
    [15, 68],
    [17, 488],
    [19, 32769],
  ]) {
    const bad = f.slice();
    new DataView(bad.buffer).setUint16(offset!, value!, true);
    expect(() => new WowLiveAssembler().observe(1, seal(bad), 0)).toThrow();
  }
});
test("mixed digests cannot combine; conflicting duplicate pages clear assembly", () => {
  const f = pages(encode(fixture())),
    other = pages(encode({ ...fixture(), consolePortVersion: "changed" }), 2),
    a = new WowLiveAssembler();
  a.observe(1, f[0]!, 0);
  expect(a.observe(1, other[1]!, 1)).toBeUndefined();
  expect(a.observe(1, tick(other[0]!, 4), 2)?.consolePortVersion).toBe(
    "changed",
  );
  const b = new WowLiveAssembler();
  b.observe(1, f[0]!, 0);
  const bad = tick(f[0]!, 2);
  bad[100] = bad[100]! ^ 1;
  expect(() => b.observe(1, seal(bad), 1)).toThrow();
  expect(b.observe(1, tick(f[1]!, 3), 2)).toBeUndefined();
});
test("partial pages copy caller bytes and whole-message checksum is verified", () => {
  const f = pages(encode(fixture())),
    a = new WowLiveAssembler();
  a.observe(1, f[0]!, 0);
  f[0]!.fill(0);
  expect(a.observe(1, f[1]!, 1)).toEqual(fixture());
  const changed = pages(encode(fixture()));
  changed[1]![30] = changed[1]![30]! ^ 1;
  seal(changed[1]!);
  const b = new WowLiveAssembler();
  b.observe(1, changed[0]!, 0);
  expect(() => b.observe(1, changed[1]!, 1)).toThrow();
});
test("strict snapshot rejects unknown/duplicate keys, invalid UTF8 and integer coercion", () => {
  const original = JSON.stringify(fixture());
  for (const source of [
    original.replace('"schema":', '"schema":"duplicate","schema":'),
    original.replace('"schema":', '"sch\\u0065ma":"duplicate","schema":'),
    original.replace('"version":1', '"version":1.0'),
    original.replace('"version":1', '"version":1e0'),
    original.replace('"version":1', '"version":-0'),
    original.replace("11509", "16001"),
    original.replace('"MAGE"', '"\\ud800"'),
  ])
    expect(() =>
      decodeWowLiveSnapshot(new TextEncoder().encode(source)),
    ).toThrow();
  for (const v of [
    { ...fixture(), extra: true },
    { ...fixture(), client: { ...fixture().client, extra: true } },
    { ...fixture(), character: { ...fixture().character, extra: true } },
  ])
    expect(() => decodeWowLiveSnapshot(encode(v))).toThrow();
  expect(() => decodeWowLiveSnapshot(Uint8Array.of(255))).toThrow();
  expect(() => decodeWowLiveSnapshot(new Uint8Array(32769))).toThrow();
  expect(
    decodeWowLiveSnapshot(
      encode({ ...fixture(), client: { flavor: "forever", interface: 16001 } }),
    ).client.flavor,
  ).toBe("forever");
});
test("character/action bounds, atlas correlation and duplicate control identities fail closed", () => {
  const base = fixture(),
    action = base.actions[0]!;
  for (const patch of [
    { id: "Account-secret" },
    { id: "Player-bad!" },
    { name: "a\n" },
    { realm: "é".repeat(49) },
    { classTag: "x".repeat(33) },
  ])
    expect(() =>
      decodeWowLiveSnapshot(
        encode({ ...base, character: { ...base.character, ...patch } }),
      ),
    ).toThrow();
  for (const patch of [
    { bank: "unknown" },
    { button: "script" },
    { slot: 181 },
    { actionID: 2147483648 },
    { iconIndex: 2 },
    { iconFileID: null },
    { command: "x".repeat(129) },
    { kind: "" },
  ])
    expect(() =>
      decodeWowLiveSnapshot(
        encode({ ...base, actions: [{ ...action, ...patch }] }),
      ),
    ).toThrow();
  for (const patch of [
    { actions: [action, action] },
    { icons: [456, 456] },
    { icons: [0] },
    { devices: Array(17).fill({ name: "test" }) },
    { actions: Array(65).fill(action) },
  ])
    expect(() =>
      decodeWowLiveSnapshot(encode({ ...base, ...patch })),
    ).toThrow();
  const optional = decodeWowLiveSnapshot(
    encode({
      ...base,
      actions: [
        {
          bank: "base",
          button: "south",
          command: "UTILITY",
          label: "Utility",
          kind: "utility",
        },
      ],
      icons: [],
      devices: [{ name: "Pad" }],
    }),
  );
  expect(optional.actions[0]?.slot).toBeNull();
  expect(optional.devices[0]?.vendorID).toBeNull();
});

test("maximum bounded message assembles exactly 68 pages into a validated synthetic snapshot", () => {
  // Valid JSON padded to the exact wire ceiling. It remains a synthetic snapshot.
  const original = JSON.stringify(fixture());
  const message = new TextEncoder().encode(
    original + " ".repeat(32768 - original.length),
  );
  const frames = pages(message),
    assembler = new WowLiveAssembler();
  expect(frames.length).toBe(68);
  let result;
  for (const [index, frame] of frames.entries())
    result = assembler.observe(1, frame, index * 10) ?? result;
  expect(result).toEqual(fixture());
});
test("out-of-order pages still use tick ordering, while source switches discard partial snapshots", () => {
  const frames = pages(encode(fixture())),
    a = new WowLiveAssembler();
  expect(a.observe(1, tick(frames[1]!, 1), 0)).toBeUndefined();
  expect(a.observe(1, tick(frames[0]!, 2), 1)).toEqual(fixture());
  const b = new WowLiveAssembler();
  b.observe(1, frames[0]!, 0);
  expect(b.observe(2, frames[1]!, 1)).toBeUndefined();
  expect(b.isLive(1)).toBe(false);
  expect(b.observe(2, tick(frames[0]!, 3), 2)).toEqual(fixture());
});
test("fatal portable UTF8 preserves legal scalars and rejects overlong/truncated/surrogate/out-of-range sequences", () => {
  const base = fixture();
  const name = "éࠀ😀";
  expect(
    decodeWowLiveSnapshot(
      encode({ ...base, character: { ...base.character, name } }),
    ).character.name,
  ).toBe(name);
  for (const bad of [
    [0x80],
    [0xc0, 0xaf],
    [0xc2],
    [0xe0, 0x80, 0xaf],
    [0xed, 0xa0, 0x80],
    [0xf0, 0x80, 0x80, 0xaf],
    [0xf4, 0x90, 0x80, 0x80],
    [0xf5, 0x80, 0x80, 0x80],
    [0xff],
  ]) {
    const prefix = new TextEncoder().encode('{"schema":"'),
      suffix = new TextEncoder().encode('"}'),
      bytes = new Uint8Array(prefix.length + bad.length + suffix.length);
    bytes.set(prefix);
    bytes.set(bad, prefix.length);
    bytes.set(suffix, prefix.length + bad.length);
    expect(() => decodeWowLiveSnapshot(bytes)).toThrow();
  }
});

test("freshness query high-water time prevents stale state from reviving through backward queries or observations", () => {
  const a = new WowLiveAssembler(),
    f = onePage();
  a.observe(1, f, 0);
  a.observe(1, tick(f, 2), 1000);
  expect(a.isLive(4000)).toBe(false);
  expect(a.isLive(1001)).toBe(false);
  expect(() => a.observe(1, tick(f, 3), 1001)).toThrow();
  expect(() => a.observe(1, tick(f, 4), 1002)).toThrow();
  expect(a.isLive(4001)).toBe(false);
  expect(a.observe(1, tick(f, 5), 4002)).toBeUndefined();
  expect(a.observe(1, tick(f, 6), 4003)).toBeDefined();
});

test("action bank enums reject coercible arrays and nonstring values", () => {
  const base = fixture(),
    action = base.actions[0]!;
  for (const bank of [
    ["base"],
    [["base"]],
    ["left-trigger"],
    [],
    {},
    null,
    0,
    true,
  ]) {
    expect(() =>
      decodeWowLiveSnapshot(
        encode({ ...base, actions: [{ ...action, bank }] }),
      ),
    ).toThrow();
  }
  for (const bank of [
    "base",
    "left-trigger",
    "right-trigger",
    "both-triggers",
  ] as const) {
    const result = decodeWowLiveSnapshot(
      encode({ ...base, actions: [{ ...action, bank }] }),
    );
    expect(result.actions[0]?.bank).toBe(bank);
    expect(typeof result.actions[0]?.bank).toBe("string");
  }
});
