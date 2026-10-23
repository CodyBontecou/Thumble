import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { createHash } from "node:crypto";
import { LosslessJson } from "@thumble/contracts/json";
import {
  decodePhoneControlsQuery,
  decodePhoneControlsEvent,
  decodePhoneControlsResult,
  phoneControlNumber,
  type PhoneControlsCommand,
} from "@thumble/contracts/phone-controls";
import { ConfigurationPhoneControlsOperations } from "@thumble/application/configuration-phone-controls";
import type {
  ConfigurationRepository,
  ConfigurationSource,
} from "@thumble/application/configuration-store";
import { OwnedAuthorityDocument } from "@thumble/domain/owned-authority";
import { configurationSourceHash } from "@thumble/storage";
import { PhoneControlsBridge } from "../apps/service/src/phone-controls-bridge.ts";
const root = resolve(import.meta.dir, ".."),
  hash = (x: string | Uint8Array) =>
    createHash("sha256").update(x).digest("hex");
const wire = JSON.parse(
  readFileSync(
    resolve(root, "packages/fixtures/saved-controller-control-v8.json"),
    "utf8",
  ),
);
const { version: _v, command: _c, connectionId: _i, ...request } = wire.request;
const query = decodePhoneControlsQuery({
  authorityInstanceId: wire.reply.authorityInstanceId,
  ...request,
});
const { version: _rv, command: _rc, connectionId: _ri, ...result } = wire.reply;
const source = () =>
  LosslessJson.parse(
    readFileSync(
      resolve(root, "packages/fixtures/saved-controller-v1.json"),
      "utf8",
    ),
  );
function fixture(value = source()) {
  let current: ConfigurationSource | undefined = {
    source: value,
    revision: "3",
    contentHash: configurationSourceHash(value),
  };
  const repository: ConfigurationRepository = {
    current: () => current,
    receipt: () => undefined,
    commit: () => {
      throw new Error("map read cannot commit");
    },
  };
  const command: PhoneControlsCommand = {
    ...query,
    command: "configuration-phone-controls",
    expectedSourceHash: current.contentHash,
    profileId: "bbbbbbbb-0000-0000-0000-000000000002",
    viewportWidth: "874.0",
    viewportHeight: "393.0",
  };
  const operations = new ConfigurationPhoneControlsOperations(repository, {
    sourceHash: configurationSourceHash,
    documentHash: hash,
    resourceHash: hash,
    readAsset: () => {
      throw new Error("no assets");
    },
  });
  return {
    operations,
    command,
    repository,
    current: () => current,
    replace: (next: ConfigurationSource | undefined) => {
      current = next;
    },
  };
}
test("shared role8 fixture pins source/epochs/viewport, strict scalar fields and all-or-none haptics", () => {
  expect(decodePhoneControlsResult(result, query)).toEqual(result);
  const event = { version: 1, event: "phone-controls", eventId: "1", ...query };
  expect(
    decodePhoneControlsEvent(event, query.authorityInstanceId).eventId,
  ).toBe("1");
  expect(() =>
    decodePhoneControlsEvent(
      { ...event, authorityInstanceId: "other" },
      query.authorityInstanceId,
    ),
  ).toThrow();
  expect(() =>
    decodePhoneControlsEvent(
      { ...event, eventId: "0" },
      query.authorityInstanceId,
    ),
  ).toThrow();
  for (const patch of [
    { generation: "8" },
    { revision: "3" },
    { configurationRevision: "4" },
    { sourceHash: "c".repeat(64) },
    { configurationSha256: "secret" },
    { profileId: "ffffffff-0000-0000-0000-000000000001" },
    { viewportWidth: "874.0" },
    { control0X: "NaN" },
    { control0Width: "1.01" },
    { control0Action: "future-action" },
    { control0HapticDuration: undefined },
    { secret: "raw-source" },
  ])
    expect(() =>
      decodePhoneControlsResult({ ...result, ...patch }, query),
    ).toThrow();
  expect(() =>
    decodePhoneControlsResult(
      { ...result, control0HapticDuration: 0.06 },
      query,
    ),
  ).toThrow();
  for (const error of wire.errors) {
    const { version: _v, command: _c, connectionId: _i, ...body } = error;
    expect(decodePhoneControlsResult(body, query).kind).toBe("error");
  }
  for (const number of [
    "NaN",
    "Infinity",
    "-0",
    "01",
    ".1",
    "1.",
    "1E-3",
    " ",
    "1e9999",
    "1".repeat(33),
  ])
    expect(() => phoneControlNumber(number)).toThrow();
  expect(phoneControlNumber("1e-7")).toBe(0.0000001);
  expect(() =>
    decodePhoneControlsQuery({ ...query, viewportHeight: "239.99" }),
  ).toThrow();
});
test("actual saved selected button profile projects without authority changes, viewport rounding or hash confusion", () => {
  const f = fixture(),
    before = f.current()!.source.text(),
    read = f.operations.execute(f.command);
  expect(read.kind).toBe("controls");
  if (read.kind !== "controls") throw new Error("expected controls");
  expect(read.profileId).toBe(f.command.profileId);
  expect(read.control0Id).toBe("db000000-0000-0000-0000-000000000002");
  expect(read.control0Action).toBe("south");
  expect(read.viewportWidth).toBe("874.0");
  expect(read.viewportHeight).toBe("393.0");
  expect(read.sourceHash).toBe(f.command.expectedSourceHash);
  expect(read.configurationSha256).toBe(hash(before));
  expect(read.configurationSha256).not.toBe(read.sourceHash);
  expect(read.generation).toBe("7");
  expect(read.revision).toBe("2");
  expect(Number(read.control0Width) * 874).toBeCloseTo(86, 10);
  expect(Number(read.control0X) + Number(read.control0Width) / 2).toBeCloseTo(
    0.5,
    12,
  );
  expect(f.current()!.source.text()).toBe(before);
  expect(f.current()!.revision).toBe("3");
  for (const patch of [
    { expectedConfigurationRevision: "4" },
    { expectedSourceHash: "c".repeat(64) },
    { profileId: "aaaaaaaa-0000-0000-0000-000000000001" },
  ])
    expect(f.operations.execute({ ...f.command, ...patch })).toEqual({
      kind: "error",
      error: "saved_map_reactivation_required",
    });
  const corrupt = fixture();
  corrupt.replace({
    ...corrupt.current()!,
    source: corrupt.current()!.source.set("/opaqueCorruption", "true"),
  });
  expect(corrupt.operations.execute(corrupt.command)).toEqual({
    kind: "error",
    error: "saved_map_unavailable",
  });
  corrupt.replace(undefined);
  expect(corrupt.operations.execute(corrupt.command)).toEqual({
    kind: "error",
    error: "saved_map_reactivation_required",
  });
  const unsupported = fixture(
    source().set(
      "/profiles/1/customization/elements/0/layout/shape",
      '"circle"',
    ),
  );
  expect(unsupported.operations.execute(unsupported.command)).toEqual({
    kind: "error",
    error: "saved_map_unsupported_profile",
  });
});
test("storage edit after projection preserves the immutable active-pin response while a new read requires reactivation", async () => {
  const f = fixture();
  let deliver!: () => void;
  const wait = new Promise<void>((resolve) => {
    deliver = resolve;
  });
  let started!: () => void;
  const projectionReady = new Promise<void>((resolve) => {
    started = resolve;
  });
  let projected: unknown;
  const bridge = new PhoneControlsBridge(async () => {
    projected = f.operations.execute(f.command);
    started();
    await wait;
    return projected;
  });
  const { command: _command, ...pins } = f.command;
  const event = {
    version: 1,
    event: "phone-controls",
    eventId: "1",
    ...pins,
  } as const;
  // The owner read linearizes before this edit; no authority lock spans delivery.
  const pending = bridge.execute(event);
  await projectionReady;
  const old = f.current()!;
  const edited = old.source.set(
    "/profiles/1/name",
    '"Edited after projection"',
  );
  f.replace({
    source: edited,
    revision: "4",
    contentHash: configurationSourceHash(edited),
  });
  expect(f.operations.execute(f.command)).toEqual({
    kind: "error",
    error: "saved_map_reactivation_required",
  });
  deliver();
  const response = await pending;
  expect("result" in response).toBe(true);
  if (!("result" in response)) throw new Error("expected frozen result");
  const map = decodePhoneControlsResult(response.result, f.command);
  expect(map.kind).toBe("controls");
  if (map.kind !== "controls") throw new Error("expected controls");
  expect(map.configurationRevision).toBe("3");
  expect(map.sourceHash).toBe(old.contentHash);
  expect(map.configurationSha256).toBe(hash(old.source.text()));
  expect(map.generation).toBe(f.command.generation);
  expect(map.revision).toBe(f.command.revision);
  expect(f.current()!.revision).toBe("4");
});
test("stored authority materializes only verified content-addressed resources and fails safely on missing/corrupt assets", () => {
  const inline = source().set(
    "/profiles/1/customization/assetLibrary",
    JSON.stringify({ assets: [{ id: "synthetic", data: "YWJj" }] }),
  );
  const prepared = OwnedAuthorityDocument.prepare(inline, hash),
    assets = prepared.assets(),
    stored = prepared.document.source,
    f = fixture(stored);
  const byHash = new Map(assets.map((a) => [hash(a), a]));
  let corrupt = false;
  const operations = new ConfigurationPhoneControlsOperations(f.repository, {
    sourceHash: configurationSourceHash,
    documentHash: hash,
    resourceHash: hash,
    readAsset: (h) => {
      const bytes = byHash.get(h);
      if (!bytes) throw new Error("missing");
      return corrupt ? new Uint8Array([0]) : bytes;
    },
  });
  const read = operations.execute(f.command);
  expect(read.kind).toBe("controls");
  if (read.kind !== "controls") throw new Error("expected controls");
  expect(read.sourceHash).toBe(configurationSourceHash(stored));
  expect(read.configurationSha256).toBe(
    hash(
      prepared.document.materialize((h) => byHash.get(h)!, hash).source.text(),
    ),
  );
  corrupt = true;
  expect(operations.execute(f.command)).toEqual({
    kind: "error",
    error: "saved_map_unavailable",
  });
  expect(stored.text()).toBe(f.current()!.source.text());
});
test("bounded parent bridge times out only the phone reply and stays busy until underlying owner read finishes", async () => {
  let complete!: (value: unknown) => void;
  const underlying = new Promise((resolve) => {
    complete = resolve;
  });
  let calls = 0;
  const bridge = new PhoneControlsBridge(() => {
    calls++;
    return underlying;
  });
  const event = {
    version: 1,
    event: "phone-controls",
    eventId: "1",
    ...query,
  } as const;
  const first = bridge.execute(event);
  expect(await bridge.execute({ ...event, eventId: "2" })).toEqual({
    error: "saved_map_busy",
  });
  expect(await first).toEqual({ error: "saved_map_timeout" });
  expect(await bridge.execute({ ...event, eventId: "3" })).toEqual({
    error: "saved_map_busy",
  });
  expect(calls).toBe(1);
  complete(result);
  await underlying;
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(await bridge.execute({ ...event, eventId: "4" })).toEqual({ result });
  expect(calls).toBe(2);
}, 5000);
