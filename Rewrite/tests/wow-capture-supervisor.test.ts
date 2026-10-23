import { expect, test } from "bun:test";
import { deflateSync, inflateSync } from "node:zlib";
import {
  parseWowCaptureRequest,
  parseWowCaptureReply,
  encodeWowCaptureRequest,
  WOW_CAPTURE_LIMITS,
  type WowCaptureRequest,
} from "@thumble/contracts/wow-capture";
import {
  WowCapturedFrame,
  validateWowAtlasContainer,
  type WowAtlasDecoder,
} from "@thumble/domain/wow-capture-receipt";
import { WowCaptureSupervisor } from "@thumble/application/wow-capture-supervisor";
import { WowLiveObserver } from "@thumble/application/wow-live-observer";
import { wowLiveChecksum } from "@thumble/domain/wow-live";
const id = { source: 42, generation: "1", receipt: "1" };
function crc(bytes: Uint8Array) {
  let c = 0xffffffff;
  for (const byte of bytes) {
    c ^= byte;
    for (let i = 0; i < 8; i++) c = (c >>> 1) ^ (c & 1 ? 0xedb88320 : 0);
  }
  return (c ^ 0xffffffff) >>> 0;
}
function chunk(type: string, data: Uint8Array = new Uint8Array()) {
  const b = Buffer.alloc(data.length + 12);
  b.writeUInt32BE(data.length);
  b.write(type, 4);
  b.set(data, 8);
  b.writeUInt32BE(crc(b.subarray(4, -4)), b.length - 4);
  return b;
}
function png(extra: Uint8Array[] = [], compressed?: Uint8Array) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(256);
  header.writeUInt32BE(256, 4);
  header[8] = 8;
  header[9] = 6;
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", header),
    ...extra,
    chunk("IDAT", compressed ?? deflateSync(Buffer.alloc(256 * 1025))),
    chunk("IEND"),
  ]);
}
const atlas = png();
const decode: WowAtlasDecoder = (bytes, limits) => {
  expect(limits).toEqual({
    width: 256,
    height: 256,
    maxDecodedBytes: 262144,
    maxInflatedBytes: 262400,
  });
  const b = Buffer.from(bytes),
    compressed: Uint8Array[] = [];
  for (let at = 8; at < b.length; ) {
    const n = b.readUInt32BE(at);
    if (b.toString("ascii", at + 4, at + 8) === "IDAT")
      compressed.push(b.subarray(at + 8, at + 8 + n));
    at += n + 12;
  }
  const raw = inflateSync(Buffer.concat(compressed), {
    maxOutputLength: limits.maxInflatedBytes,
  });
  if (raw.length !== 262400) throw Error("invalid raster");
  const rgba = new Uint8Array(262144);
  for (let y = 0; y < 256; y++) {
    if (raw[y * 1025] !== 0) throw Error("fixture filter");
    rgba.set(raw.subarray(y * 1025 + 1, (y + 1) * 1025), y * 1024);
  }
  return { width: 256, height: 256, rgba };
};
function frame() {
  const value = {
    schema: "thumble.wow-live",
    version: 1,
    client: { flavor: "classic-era", interface: 11509 },
    character: {
      id: "Player-Synthetic",
      name: "Synthetic",
      realm: "Fixture",
      classTag: "MAGE",
    },
    actions: [],
    icons: [],
    devices: [],
    consolePortVersion: "absent",
  };
  const payload = Buffer.from(JSON.stringify(value));
  const b = new Uint8Array(512),
    v = new DataView(b.buffer);
  b.set([84, 72, 87, 76, 1]);
  v.setUint32(5, 1, true);
  v.setUint32(9, wowLiveChecksum(payload), true);
  v.setUint16(15, 1, true);
  v.setUint16(17, payload.length, true);
  v.setUint16(19, payload.length, true);
  b.set(payload, 25);
  v.setUint32(
    21,
    wowLiveChecksum(Buffer.concat([b.subarray(0, 21), payload])),
    true,
  );
  return b;
}
function reply(request = id, patch: Record<string, unknown> = {}) {
  return JSON.stringify({
    version: 1,
    command: "wow-capture-result",
    source: request.source,
    generation: request.generation,
    receipt: request.receipt,
    kind: "frame",
    frameBase64: Buffer.from(frame()).toString("base64"),
    atlasPNGBase64: atlas.toString("base64"),
    ...patch,
  });
}
function deferred<T>() {
  let resolve!: (value: T) => void, reject!: (error: unknown) => void;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}
const flush = async () => {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
};
function harness(generation = "0", receipt = "0", decoder = decode) {
  let now = 0;
  const tasks = new Set<{ due: number; run: () => void }>();
  const providers: Array<{
    requests: WowCaptureRequest[];
    answers: ReturnType<typeof deferred<string>>[];
    stop: ReturnType<typeof deferred<void>>;
    stops: number;
  }> = [];
  const supervisor = new WowCaptureSupervisor(
    {
      clock: () => now,
      schedule: (delay, run) => {
        const task = { due: now + delay, run };
        tasks.add(task);
        return () => {
          tasks.delete(task);
        };
      },
      create: () => {
        const p = {
          requests: [] as WowCaptureRequest[],
          answers: [] as ReturnType<typeof deferred<string>>[],
          stop: deferred<void>(),
          stops: 0,
        };
        providers.push(p);
        return {
          capture: (request) => {
            p.requests.push(parseWowCaptureRequest(request));
            const answer = deferred<string>();
            p.answers.push(answer);
            return answer.promise;
          },
          stop: () => {
            p.stops++;
            return p.stop.promise;
          },
        };
      },
      decodeAtlas: decoder,
    },
    generation,
    receipt,
  );
  return {
    supervisor,
    providers,
    setTime: (value: number) => {
      now = value;
    },
    advance: (value: number) => {
      now = value;
      for (;;) {
        const next = [...tasks]
          .filter((t) => t.due <= now)
          .sort((a, b) => a.due - b.due)[0];
        if (!next) break;
        tasks.delete(next);
        next.run();
      }
    },
    tasks,
  };
}
test("strict child codec bounds identities, duplicate keys, fields and canonical base64", () => {
  const request = { version: 1, command: "wow-capture", ...id } as const;
  expect(parseWowCaptureRequest(encodeWowCaptureRequest(request))).toEqual(
    request,
  );
  for (const text of [
    JSON.stringify({ ...request, windowID: 1 }),
    JSON.stringify({ ...request, path: "/private" }),
    JSON.stringify({ ...request, source: 0 }),
    JSON.stringify({ ...request, source: 4294967296 }),
    JSON.stringify({ ...request, generation: "01" }),
    JSON.stringify({ ...request, receipt: "18446744073709551616" }),
    '{"version":1,"version":1}',
    JSON.stringify({ ...request, receipt: 1 }),
    " ".repeat(257),
    '{"source":{}}',
  ])
    expect(() => parseWowCaptureRequest(text)).toThrow(
      "invalid_wow_capture_message",
    );
  expect(parseWowCaptureReply(reply(), id).kind).toBe("frame");
  for (const patch of [
    { source: 43 },
    { generation: "2" },
    { receipt: "2" },
    { frameBase64: "AA==" },
    { atlasPNGBase64: "AB==" },
    { atlasPNGBase64: "AAAA=" },
    { windowID: 42 },
    {
      atlasPNGBase64: "A".repeat(
        4 * Math.ceil((WOW_CAPTURE_LIMITS.atlasBytes + 3) / 3),
      ),
    },
  ])
    expect(() => parseWowCaptureReply(reply(id, patch), id)).toThrow(
      "invalid_wow_capture_message",
    );
  expect(() =>
    parseWowCaptureReply(
      reply().replace('"source":42', '"source":42,"\\u0073ource":42'),
      id,
    ),
  ).toThrow();
  expect(() =>
    parseWowCaptureReply("x".repeat(WOW_CAPTURE_LIMITS.replyBytes + 1), id),
  ).toThrow();
  expect(() =>
    parseWowCaptureReply(reply(id, { frameBase64: [1, 2] }), id),
  ).toThrow();
  for (const status of [
    "permission-required",
    "game-not-visible",
    "multiple-game-windows",
    "panel-not-visible",
    "unavailable",
  ])
    expect(
      parseWowCaptureReply(
        JSON.stringify({
          version: 1,
          command: "wow-capture-result",
          ...id,
          kind: "status",
          status,
        }),
        id,
      ),
    ).toMatchObject({ kind: "status", status });
});
test("same-receipt immutable bytes require THWL and bounded PNG container plus actual decoder output", () => {
  const message = parseWowCaptureReply(reply(), id);
  if (message.kind !== "frame") throw Error("frame");
  const captured = new WowCapturedFrame(message, 10, decode);
  message.frame.fill(0);
  message.atlasPNG.fill(0);
  expect(captured.frame()).toEqual(frame());
  expect(captured.atlasPNG()).toEqual(atlas);
  captured.frame().fill(0);
  captured.atlasPNG().fill(0);
  expect(captured.frame()).toEqual(frame());
  expect(captured.atlasPNG()).toEqual(atlas);
  expect(Object.isFrozen(captured)).toBe(true);
  expect(() =>
    validateWowAtlasContainer(
      png(Array.from({ length: 256 }, () => chunk("teXT"))),
    ),
  ).toThrow("invalid_wow_capture_atlas");
  const corrupt = Buffer.from(atlas);
  corrupt[corrupt.length - 1] = corrupt[corrupt.length - 1]! ^ 1;
  expect(() => validateWowAtlasContainer(corrupt)).toThrow();
  const wrong = Buffer.from(atlas);
  wrong.writeUInt32BE(257, 16);
  wrong.writeUInt32BE(crc(wrong.subarray(12, 29)), 29);
  expect(() => validateWowAtlasContainer(wrong)).toThrow();
  const invalidPixels = png([], new Uint8Array([1, 2, 3]));
  expect(() => validateWowAtlasContainer(invalidPixels)).not.toThrow();
  const bad = parseWowCaptureReply(
    reply(id, { atlasPNGBase64: invalidPixels.toString("base64") }),
    id,
  );
  if (bad.kind !== "frame") throw Error("frame");
  expect(() => new WowCapturedFrame(bad, 10, decode)).toThrow(
    "invalid_wow_capture_atlas",
  );
  const clean = parseWowCaptureReply(reply(), id);
  if (clean.kind !== "frame") throw Error("frame");
  for (const verifier of [
    () => ({ width: 255, height: 256, rgba: new Uint8Array(262144) }),
    () => ({ width: 256, height: 256, rgba: new Uint8Array(1) }),
  ])
    expect(() => new WowCapturedFrame(clean, 10, verifier)).toThrow(
      "invalid_wow_capture_atlas",
    );
  expect(
    () =>
      new WowCapturedFrame(
        { ...clean, frame: new Uint8Array(511) },
        10,
        decode,
      ),
  ).toThrow();
});
test("one inflight and one coalesced demand publish latest only without automatic observer ACK", async () => {
  const h = harness(),
    s = h.supervisor;
  s.start(42);
  s.request();
  const p = h.providers[0]!;
  for (let i = 0; i < 10000; i++) s.request();
  expect(p.requests).toHaveLength(1);
  expect(h.providers).toHaveLength(1);
  p.answers[0]!.resolve(reply(p.requests[0]!));
  await flush();
  expect(p.requests).toHaveLength(2);
  expect(s.take()).toBeUndefined();
  p.answers[1]!.resolve(reply(p.requests[1]!));
  await flush();
  const captured = s.take();
  expect(captured).toBeInstanceOf(WowCapturedFrame);
  expect(s.take()).toBeUndefined();
  expect(s.isCurrent(captured!)).toBe(true);
  if (!(captured instanceof WowCapturedFrame)) throw Error("frame");
  const observer = new WowLiveObserver();
  expect(
    observer.observe(
      captured.source,
      captured.generation,
      captured.frame(),
      captured.observedAtMs,
    ),
  ).toBeUndefined();
  expect(observer.isLive(0)).toBe(false);
  expect(observer.pending(0)).toBeUndefined();
  s.request();
  expect(s.isCurrent(captured)).toBe(false);
  expect(p.requests).toHaveLength(3);
});
test("source switch, resize/restart and stop invalidate old receipts until confirmed termination", async () => {
  const h = harness(),
    s = h.supervisor;
  s.start(42);
  s.request();
  const old = h.providers[0]!;
  s.start(43);
  s.request();
  expect(old.stops).toBe(1);
  expect(h.providers).toHaveLength(1);
  expect(s.status()).toMatchObject({
    state: "stopping",
    source: 43,
    generation: "2",
  });
  old.answers[0]!.resolve(reply(old.requests[0]!));
  await flush();
  expect(s.take()).toBeUndefined();
  expect(h.providers).toHaveLength(1);
  old.stop.resolve();
  await flush();
  expect(h.providers).toHaveLength(2);
  const current = h.providers[1]!;
  expect(current.requests[0]).toMatchObject({
    source: 43,
    generation: "2",
    receipt: "2",
  });
  current.answers[0]!.resolve(reply(current.requests[0]!));
  await flush();
  const receipt = s.take()!;
  expect(s.isCurrent(receipt)).toBe(true);
  s.start(43);
  expect(s.isCurrent(receipt)).toBe(false);
  expect(s.status().generation).toBe("3");
  const stopping = s.stop();
  expect(s.stop()).toBe(stopping);
  current.stop.resolve();
  expect(await stopping).toBe("stopped");
  expect(s.take()).toBeUndefined();
});
test("hang and bounded stop timeout retain ownership and reject late/replayed responses", async () => {
  const h = harness(),
    s = h.supervisor;
  s.start(42);
  s.request();
  const p = h.providers[0]!;
  h.advance(2000);
  expect(p.stops).toBe(1);
  const stopping = s.stop();
  h.advance(2500);
  expect(await stopping).toBe("unavailable");
  s.start(42);
  for (let i = 0; i < 1000; i++) s.request();
  expect(h.providers).toHaveLength(1);
  p.answers[0]!.resolve(reply(p.requests[0]!));
  await flush();
  expect(h.providers).toHaveLength(1);
  expect(s.take()).toBeUndefined();
  p.stop.resolve();
  await flush();
  expect(h.providers).toHaveLength(2);
  const next = h.providers[1]!;
  next.answers[0]!.resolve(reply(p.requests[0]!));
  await flush();
  expect(s.take()).toBeUndefined();
  expect(next.stops).toBe(1);
});
test("death, failed stop, malformed reply and decoder failure publish only fixed state", async () => {
  for (const mode of ["death", "malformed", "decode"]) {
    const h = harness(
        "0",
        "0",
        mode === "decode"
          ? () => {
              throw Error("sensitive pixels");
            }
          : decode,
      ),
      s = h.supervisor;
    s.start(42);
    s.request();
    const p = h.providers[0]!;
    if (mode === "death") p.answers[0]!.reject(Error("private child path"));
    else
      p.answers[0]!.resolve(
        mode === "malformed" ? "private invalid body" : reply(p.requests[0]!),
      );
    await flush();
    expect(s.take()).toBeUndefined();
    expect(p.stops).toBe(1);
    p.stop.reject(Error("private termination failure"));
    expect(await s.stop()).toBe("unavailable");
    s.start(43);
    s.request();
    expect(h.providers).toHaveLength(1);
    expect(JSON.stringify(s.status())).not.toContain("private");
  }
});
test("status does not create game freshness and clock rollback cannot revive expired work", async () => {
  const h = harness(),
    s = h.supervisor;
  s.start(42);
  s.request();
  const p = h.providers[0]!,
    request = p.requests[0]!;
  p.answers[0]!.resolve(
    JSON.stringify({
      version: 1,
      command: "wow-capture-result",
      source: request.source,
      generation: request.generation,
      receipt: request.receipt,
      kind: "status",
      status: "panel-not-visible",
    }),
  );
  await flush();
  expect(s.take()).toMatchObject({
    kind: "status",
    status: "panel-not-visible",
  });
  s.request();
  p.answers[1]!.resolve(reply(p.requests[1]!));
  await flush();
  const captured = s.take()!;
  h.setTime(1999);
  expect(s.isCurrent(captured)).toBe(true);
  h.setTime(2000);
  expect(s.isCurrent(captured)).toBe(false);
  h.setTime(1000);
  expect(s.isCurrent(captured)).toBe(false);
  expect(s.status().state).toBe("unavailable");
  h.setTime(2000);
  expect(s.isCurrent(captured)).toBe(false);
});
test("counter and clock overflow never wrap identities", () => {
  const max = "18446744073709551615";
  expect(() => harness(max).supervisor.start(42)).toThrow(
    "wow_capture_generation_exhausted",
  );
  const h = harness("0", max);
  h.supervisor.start(42);
  h.supervisor.request();
  expect(h.supervisor.take()).toBeUndefined();
  expect(h.providers[0]?.requests ?? []).toHaveLength(0);
  const clock = harness();
  clock.setTime(Number.MAX_SAFE_INTEGER);
  clock.supervisor.start(1);
  clock.supervisor.request();
  expect(clock.supervisor.take()).toBeUndefined();
  for (const source of [0, -1, 4294967296, NaN, 1.5])
    expect(() => harness().supervisor.start(source)).toThrow(
      "invalid_wow_capture_source",
    );
  expect(() => harness("01")).toThrow("invalid_wow_capture_message");
});

test("late completion is rejected even when timer dispatch is delayed and repeated capture receipts do not freshen frozen game ticks", async () => {
  const h = harness(),
    s = h.supervisor;
  s.start(42);
  s.request();
  const p = h.providers[0]!;
  h.setTime(2000);
  p.answers[0]!.resolve(reply(p.requests[0]!));
  await flush();
  expect(s.take()).toBeUndefined();
  expect(p.stops).toBe(1);
  const repeated = harness(),
    observer = new WowLiveObserver();
  repeated.supervisor.start(42);
  for (const now of [0, 1000, 1999]) {
    repeated.setTime(now);
    repeated.supervisor.request();
    const child = repeated.providers[0]!,
      n = child.answers.length - 1;
    child.answers[n]!.resolve(reply(child.requests[n]!));
    await flush();
    const receipt = repeated.supervisor.take();
    expect(receipt).toBeInstanceOf(WowCapturedFrame);
    if (!(receipt instanceof WowCapturedFrame)) throw Error("frame");
    expect(
      observer.observe(
        receipt.source,
        receipt.generation,
        receipt.frame(),
        receipt.observedAtMs,
      ),
    ).toBeUndefined();
    expect(observer.isLive(now)).toBe(false);
  }
});
test("valid PNG framing cannot bypass bounded decompression with a compressed raster bomb", () => {
  const bomb = png([], deflateSync(new Uint8Array(1024 * 1024)));
  expect(() => validateWowAtlasContainer(bomb)).not.toThrow();
  const payload = parseWowCaptureReply(
    reply(id, { atlasPNGBase64: bomb.toString("base64") }),
    id,
  );
  if (payload.kind !== "frame") throw Error("frame");
  expect(() => new WowCapturedFrame(payload, 0, decode)).toThrow(
    "invalid_wow_capture_atlas",
  );
});

test("atlas verification cannot publish after its absolute capture deadline", async () => {
  let advance: (now: number) => void = () => {};
  const h = harness("0", "0", (bytes, limits) => {
    const decoded = decode(bytes, limits);
    advance(2000);
    return decoded;
  });
  advance = h.setTime;
  h.supervisor.start(42);
  h.supervisor.request();
  const p = h.providers[0]!;
  p.answers[0]!.resolve(reply(p.requests[0]!));
  await flush();
  expect(h.supervisor.take()).toBeUndefined();
  expect(p.stops).toBe(1);
});
