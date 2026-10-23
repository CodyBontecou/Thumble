import { expect, test } from "bun:test";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { SqliteConfigurationRepository } from "@thumble/storage";
import { starterConfiguration } from "@thumble/domain/starter-configuration";
import { ConfigurationOwner } from "../apps/service/src/configuration-owner.ts";
import { confirmEditorWriterExit } from "../apps/service/src/editor-owner-exit.ts";
import {
  PhoneEditorBridge,
  decodePhoneEditorEvent,
} from "../apps/service/src/phone-editor-bridge.ts";
import {
  decodeEditorOwnerReadResponse,
  type EditorLabelCommit,
  type EditorReadEnvelope,
} from "../apps/service/src/editor-owner-envelope.ts";
const id = "11111111-0000-0000-0000-000000000001",
  profileId = "10000000-0000-0000-0000-000000000001",
  controlId = "ce000000-0000-0000-0000-000000000001";
const intent = {
  command: "configuration-set-control-label" as const,
  operationId: "edit-one",
  expectedRevision: "1",
  profileId,
  controlId,
  label: "Jump",
};
function write(eventId = "1"): EditorLabelCommit {
  return {
    command: "editor-label-commit",
    ownerLifetimeId: id,
    eventId,
    authorityInstanceId: id,
    phoneId: "phone-a",
    credentialEpoch: "1",
    intent,
  };
}
// Build without spreading a write-only intent field into the strict read DTO.
function status(eventId = "2"): EditorReadEnvelope {
  const { intent: _, ...base } = write(eventId);
  return {
    ...base,
    command: "editor-read",
    query: { command: "editor-label-status", intent },
  };
}
const writeEvent = (envelope = write()) => ({
  version: 1,
  event: "phone-editor-write",
  envelope,
});
const readEvent = (envelope = status()) => ({
  version: 1,
  event: "phone-editor-read",
  envelope,
});
function deferred<T>() {
  let resolve!: (v: T) => void;
  const promise = new Promise<T>((r) => (resolve = r));
  return { resolve, promise };
}
function fake() {
  const pending =
    deferred<Awaited<ReturnType<ConfigurationOwner["commitEditorLabel"]>>>();
  const calls: EditorLabelCommit[] = [];
  let closed = 0;
  const owner = {
    editorOwnerLifetime: async () => id,
    retireEditorOwner: async () => {},
    closeEditorDispatch: () => {
      closed++;
    },
    commitEditorLabel: async (envelope: EditorLabelCommit) => {
      calls.push(envelope);
      return pending.promise;
    },
    readEditor: async (envelope: EditorReadEnvelope) =>
      decodeEditorOwnerReadResponse(
        {
          envelope,
          outcome: {
            version: 1,
            kind: "editor-label-pending",
            operationId: intent.operationId,
          },
        },
        envelope,
      ),
  };
  return {
    owner,
    pending,
    calls,
    get closed() {
      return closed;
    },
  };
}
test("private bridge rejects forged correlation, stale IDs, accessors, arbitrary commands and paths", async () => {
  const f = fake(),
    bridge = await PhoneEditorBridge.capture(f.owner);
  expect(bridge.enableCommand()).toEqual({
    command: "phone-editor-enable",
    ownerLifetimeId: id,
  });
  for (const event of [
    writeEvent({
      ...write(),
      ownerLifetimeId: "22222222-0000-0000-0000-000000000002",
    }),
    writeEvent({ ...write(), eventId: "0" }),
    writeEvent({ ...write(), eventId: "18446744073709551616" }),
  ])
    await expect(bridge.execute(event)).rejects.toThrow();
  for (const event of [
    { ...writeEvent(), path: "/tmp" },
    writeEvent({
      ...write(),
      intent: { ...intent, command: "configuration-list" } as never,
    }),
    Object.defineProperty({ ...writeEvent() }, "envelope", {
      get() {
        throw Error("getter_executed");
      },
    }),
  ])
    expect(() => decodePhoneEditorEvent(event)).toThrow();
  expect(f.calls).toHaveLength(0);
  await bridge.execute(readEvent());
  await expect(bridge.execute(readEvent())).rejects.toThrow();
  await expect(bridge.execute(writeEvent())).rejects.toThrow();
  expect(f.calls).toHaveLength(0);
});
test("pending write slot survives readonly completion and close until captured actual owner settles", async () => {
  const f = fake(),
    bridge = await PhoneEditorBridge.capture(f.owner);
  let settled = false;
  const pending = bridge.execute(writeEvent()).then((r) => {
    settled = true;
    return r;
  });
  await Promise.resolve();
  expect(await bridge.execute(readEvent())).toMatchObject({
    event: "phone-editor-read-reply",
    result: {
      kind: "read-response",
      response: { outcome: { kind: "editor-label-pending" } },
    },
  });
  expect(settled).toBe(false);
  expect(await bridge.execute(writeEvent(write("3")))).toMatchObject({
    result: { kind: "not-dispatched", error: "configuration_owner_busy" },
  });
  bridge.close();
  expect(settled).toBe(false);
  await expect(bridge.execute(writeEvent(write("4")))).rejects.toThrow();
  const envelope = f.calls[0]!;
  f.pending.resolve({
    kind: "owner-response",
    response: {
      envelope,
      outcome: { version: 1, kind: "conflict", currentRevision: "2" },
    },
  });
  expect(await pending).toMatchObject({
    event: "phone-editor-write-reply",
    envelope,
    result: {
      kind: "owner-response",
      response: { outcome: { kind: "conflict" } },
    },
  });
  expect(f.calls).toHaveLength(1);
});
test("lost or malformed owner response never fabricates definitive completion or leaks raw errors", async () => {
  const f = fake(),
    bridge = await PhoneEditorBridge.capture(f.owner);
  const pending = bridge.execute(writeEvent());
  f.pending.resolve({
    kind: "owner-response",
    response: {
      envelope: { ...write(), eventId: "other" },
      outcome: { version: 1, kind: "conflict", currentRevision: "2" },
    },
  });
  expect(await pending).toMatchObject({
    result: { kind: "transport-uncertain", disposition: "unknown" },
  });
  expect(f.closed).toBe(1);
  await expect(bridge.execute(writeEvent(write("2")))).rejects.toThrow();
  const other = fake(),
    bridge2 = await PhoneEditorBridge.capture(other.owner);
  const p = bridge2.execute(writeEvent());
  other.pending.resolve({
    kind: "owner-error",
    error: "secret path /Users/private",
  });
  expect(await p).toMatchObject({
    result: { kind: "owner-error", error: "editor_unavailable" },
  });
});
test("readonly decoder binds pins, offset, full intent and exact receipts", () => {
  const request = status();
  const receipt = {
    version: 1,
    operationId: intent.operationId,
    resultingRevision: "2",
    contentHash: "a".repeat(64),
    affectedEntities: [profileId, controlId],
  };
  expect(
    decodeEditorOwnerReadResponse(
      {
        envelope: request,
        outcome: { version: 1, kind: "editor-label-receipt", receipt },
      },
      request,
    ).outcome.kind,
  ).toBe("editor-label-receipt");
  for (const bad of [
    { ...receipt, operationId: "other" },
    { ...receipt, resultingRevision: "3" },
    { ...receipt, affectedEntities: [controlId, profileId] },
  ])
    expect(() =>
      decodeEditorOwnerReadResponse(
        {
          envelope: request,
          outcome: { version: 1, kind: "editor-label-receipt", receipt: bad },
        },
        request,
      ),
    ).toThrow();
  expect(() =>
    decodeEditorOwnerReadResponse(
      {
        envelope: status("3"),
        outcome: {
          version: 1,
          kind: "editor-label-pending",
          operationId: intent.operationId,
        },
      },
      request,
    ),
  ).toThrow();
  const profile: EditorReadEnvelope = {
    ...request,
    query: {
      command: "editor-profile",
      expectedRevision: "1",
      expectedSourceHash: "a".repeat(64),
      profileId,
      offset: 0,
    },
  };
  const page = {
    version: 1,
    kind: "editor-profile",
    revision: "1",
    contentHash: "a".repeat(64),
    profileId,
    name: "Editor",
    offset: 0,
    totalControls: 0,
    nextOffset: null,
    controls: [],
  };
  expect(
    decodeEditorOwnerReadResponse({ envelope: profile, outcome: page }, profile)
      .outcome.kind,
  ).toBe("editor-profile");
  for (const bad of [
    { ...page, revision: "2" },
    { ...page, contentHash: "b".repeat(64) },
    { ...page, profileId: controlId },
  ])
    expect(() =>
      decodeEditorOwnerReadResponse(
        { envelope: profile, outcome: bad },
        profile,
      ),
    ).toThrow();
});
test("real child reads pinned profile and original intent receipt without reexecuting a label write", async () => {
  const executable = resolve(
      import.meta.dir,
      "../native/receiver/target/debug/thumble-rewrite-receiver",
    ),
    cli = resolve(import.meta.dir, "../apps/cli/src/main.ts");
  const parent = realpathSync(
      mkdtempSync(join(tmpdir(), "thumble-editor-read-owner-")),
    ),
    directory = join(parent, "runtime");
  const seed = new SqliteConfigurationRepository(directory, executable);
  seed.commit({
    operationId: "seed",
    payloadHash: "a".repeat(64),
    expectedRevision: "0",
    source: starterConfiguration(profileId, "Editor", "100"),
    affectedEntities: [profileId],
  });
  const current = seed.current()!;
  seed.close();
  const owner = new ConfigurationOwner(executable, directory, [
    process.execPath,
    cli,
  ]);
  try {
    const lifetime = await owner.editorOwnerLifetime(),
      bridge = await PhoneEditorBridge.capture(owner);
    const request = {
      ...status("1"),
      ownerLifetimeId: lifetime,
      query: {
        command: "editor-profile" as const,
        expectedRevision: "1",
        expectedSourceHash: current.contentHash,
        profileId,
        offset: 0,
      },
    };
    expect(await bridge.execute(readEvent(request))).toMatchObject({
      result: {
        kind: "read-response",
        response: {
          outcome: { kind: "editor-profile", revision: "1", profileId },
        },
      },
    });
    expect(
      await bridge.execute(
        readEvent({ ...status("2"), ownerLifetimeId: lifetime }),
      ),
    ).toMatchObject({
      result: { response: { outcome: { kind: "editor-label-pending" } } },
    });
    expect(
      await bridge.execute(
        writeEvent({ ...write("3"), ownerLifetimeId: lifetime }),
      ),
    ).toMatchObject({
      result: {
        kind: "owner-response",
        response: { outcome: { kind: "committed" } },
      },
    });
    expect(
      await bridge.execute(
        readEvent({ ...status("4"), ownerLifetimeId: lifetime }),
      ),
    ).toMatchObject({
      result: {
        response: {
          outcome: {
            kind: "editor-label-receipt",
            receipt: { resultingRevision: "2" },
          },
        },
      },
    });
    expect(
      await bridge.execute(
        readEvent({ ...status("5"), ownerLifetimeId: lifetime }),
      ),
    ).toMatchObject({
      result: {
        response: {
          outcome: {
            kind: "editor-label-receipt",
            receipt: { resultingRevision: "2" },
          },
        },
      },
    });
    expect(
      await owner.request({
        command: "configuration-list",
        expectedRevision: null,
        offset: 0,
      }),
    ).toMatchObject({ kind: "catalog", revision: "2" });
    await expect(
      owner.readEditor({ ...request, ownerLifetimeId: id }),
    ).rejects.toThrow("editor_owner_lifetime_mismatch");
  } finally {
    owner.disconnect();
    await confirmEditorWriterExit(owner.child);
    rmSync(parent, { recursive: true, force: true });
  }
}, 15000);
