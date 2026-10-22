import { expect, test } from "bun:test";
import {
  decodePhoneCatalogEvent,
  decodePhoneCatalogNotification,
  projectPhoneCatalog,
} from "@thumble/contracts/phone-catalog";
import { PhoneCatalogBridge } from "../apps/service/src/phone-catalog-bridge.ts";
const authority = "test-authority";
const event = {
  version: 1,
  event: "phone-catalog",
  eventId: "1",
  authorityInstanceId: authority,
  expectedRevision: null,
  offset: 0,
};
const empty = {
  version: 1,
  kind: "catalog",
  revision: "0",
  contentHash: null,
  profiles: [],
  activeProfileId: null,
  defaultProfileId: null,
  nextOffset: null,
};
const command = {
  command: "configuration-list",
  expectedRevision: null,
  offset: 0,
} as const;
test("phone catalog events admit only revision-pinned read metadata and exact authority", () => {
  expect(decodePhoneCatalogEvent(event, authority).eventId).toBe("1");
  expect(
    decodePhoneCatalogEvent(
      { ...event, eventId: "18446744073709551615" },
      authority,
    ).eventId,
  ).toBe("18446744073709551615");
  for (const patch of [
    { authorityInstanceId: "other" },
    { eventId: "0" },
    { eventId: "01" },
    { eventId: "18446744073709551616" },
    { offset: 1 },
    { offset: 256 },
    { token: "private" },
    { command: "configuration-rename-profile" },
  ])
    expect(() =>
      decodePhoneCatalogEvent({ ...event, ...patch }, authority),
    ).toThrow();
});
test("catalog projection contains only validated flat metadata", () => {
  expect(projectPhoneCatalog(empty, command)).toEqual({
    kind: "catalog",
    revision: "0",
    contentHash: null,
    activeProfileId: null,
    defaultProfileId: null,
    nextOffset: null,
    profileCount: 0,
  });
  expect(() =>
    projectPhoneCatalog({ ...empty, path: "secret" }, command),
  ).toThrow();
  expect(
    projectPhoneCatalog(
      { version: 1, kind: "conflict", currentRevision: "2" },
      { ...command, expectedRevision: "1" },
    ),
  ).toEqual({ kind: "conflict", currentRevision: "2" });
});
test("one pending read survives phone abandonment; later completion releases admission", async () => {
  let complete!: (value: unknown) => void;
  let calls = 0;
  const bridge = new PhoneCatalogBridge(() => {
    calls++;
    return new Promise((resolve) => {
      complete = resolve;
    });
  });
  const first = bridge.execute(decodePhoneCatalogEvent(event, authority));
  await Promise.resolve();
  expect(
    await bridge.execute(
      decodePhoneCatalogEvent({ ...event, eventId: "2" }, authority),
    ),
  ).toEqual({ error: "phone_catalog_busy" });
  expect(await first).toEqual({ error: "phone_catalog_timeout" });
  expect(
    await bridge.execute(
      decodePhoneCatalogEvent({ ...event, eventId: "3" }, authority),
    ),
  ).toEqual({ error: "phone_catalog_busy" });
  expect(calls).toBe(1);
  complete(empty);
  await new Promise((resolve) => setTimeout(resolve, 0));
  const next = bridge.execute(
    decodePhoneCatalogEvent({ ...event, eventId: "4" }, authority),
  );
  await Promise.resolve();
  complete(empty);
  expect(await next).toHaveProperty("result.profileCount", 0);
  expect(calls).toBe(2);
});
test("bridge sanitizes unavailable and invalid owner replies", async () => {
  for (const value of [
    () => Promise.reject(new Error("secret-path")),
    () =>
      Promise.resolve({
        ...empty,
        profiles: [{ id: "bad", name: "x", updatedAt: "0" }],
      }),
  ]) {
    expect(
      await new PhoneCatalogBridge(value).execute(
        decodePhoneCatalogEvent(event, authority),
      ),
    ).toEqual({ error: "phone_catalog_unavailable" });
  }
  expect(
    await new PhoneCatalogBridge(() =>
      Promise.reject(new Error("configuration_owner_busy")),
    ).execute(decodePhoneCatalogEvent(event, authority)),
  ).toEqual({ error: "phone_catalog_busy" });
});

test("slow owner read outlives phone deadline without poisoning child or admitting queued operator work", async () => {
  const { ConfigurationOwner } = await import(
    "../apps/service/src/configuration-owner.ts"
  );
  const { resolve } = await import("node:path");
  const { once } = await import("node:events");
  const owner = new ConfigurationOwner("unused", "unused", [
    process.execPath,
    resolve(import.meta.dir, "fixtures/slow-catalog-owner.ts"),
  ]);
  try {
    await owner.ready;
    const bridge = new PhoneCatalogBridge((command) =>
      owner.readCatalogForPhone(command),
    );
    const pending = bridge.execute(decodePhoneCatalogEvent(event, authority));
    await Bun.sleep(20);
    expect(await owner.request(command).catch((e: Error) => e.message)).toBe(
      "configuration_owner_busy",
    );
    expect(
      await owner.readCatalogForPhone(command).catch((e: Error) => e.message),
    ).toBe("configuration_owner_busy");
    expect(await pending).toEqual({ error: "phone_catalog_timeout" });
    expect(owner.child.exitCode).toBeNull();
    expect(await owner.request(command).catch((e: Error) => e.message)).toBe(
      "configuration_owner_busy",
    );
    await Bun.sleep(600);
    expect((await owner.request(command)).kind).toBe("catalog");
  } finally {
    const exited = once(owner.child, "exit");
    owner.disconnect();
    const timer = setTimeout(() => owner.child.kill("SIGKILL"), 1000);
    try {
      await exited;
    } finally {
      clearTimeout(timer);
    }
  }
}, 10000);

test("native catalog notifications reject hidden fields, malformed scalars, and unrequested conflicts", () => {
  const flat = projectPhoneCatalog(empty, command);
  if (flat.kind !== "catalog") throw new Error("test_catalog_missing");
  expect(decodePhoneCatalogNotification(flat)).toEqual(flat);
  expect(
    decodePhoneCatalogNotification({
      kind: "error",
      error: "phone_catalog_timeout",
    }),
  ).toEqual({ kind: "error", error: "phone_catalog_timeout" });
  for (const value of [
    { ...flat, token: "private" },
    { ...flat, profileCount: 17 },
    { ...flat, profileCount: 1 },
    { ...flat, revision: "01" },
    { kind: "conflict", currentRevision: "2" },
    { kind: "error", error: "secret-path" },
  ])
    expect(() => decodePhoneCatalogNotification(value)).toThrow();
});

test("invalid internal read request cannot latch the single pending slot", async () => {
  const bridge = new PhoneCatalogBridge(async () => empty);
  const valid = decodePhoneCatalogEvent(event, authority);
  await expect(bridge.execute({ ...valid, offset: 256 })).rejects.toThrow();
  expect(await bridge.execute(valid)).toHaveProperty("result.profileCount", 0);
});

test("malformed phone catalog child result terminates its poisoned owner", async () => {
  const { ConfigurationOwner } = await import(
    "../apps/service/src/configuration-owner.ts"
  );
  const { resolve } = await import("node:path");
  const { once } = await import("node:events");
  const owner = new ConfigurationOwner("unused", "unused", [
    process.execPath,
    resolve(import.meta.dir, "fixtures/invalid-configuration-owner.ts"),
  ]);
  const exited = once(owner.child, "exit");
  let deadline: ReturnType<typeof setTimeout> | undefined;
  try {
    await owner.ready;
    await expect(owner.readCatalogForPhone(command)).rejects.toThrow(
      "configuration_response_invalid",
    );
    await Promise.race([
      exited,
      new Promise((_, reject) => {
        deadline = setTimeout(
          () => reject(new Error("poisoned_owner_not_terminated")),
          1000,
        );
      }),
    ]);
    expect(
      owner.child.exitCode !== null || owner.child.signalCode !== null,
    ).toBe(true);
  } finally {
    clearTimeout(deadline);
    owner.disconnect();
    if (owner.child.exitCode === null && owner.child.signalCode === null)
      owner.child.kill("SIGKILL");
    await exited;
  }
});
