import { expect, test } from "bun:test";
import { EventEmitter } from "node:events";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import type { ChildProcessWithoutNullStreams } from "node:child_process";
import { SqliteConfigurationRepository } from "@thumble/storage";
import { starterConfiguration } from "@thumble/domain/starter-configuration";
import {
  NativePipe,
  NativePipeTransportLost,
} from "../apps/service/src/native-pipe.ts";
import { ConfigurationOwner } from "../apps/service/src/configuration-owner.ts";
import {
  decodeEditorLabelCommit,
  decodeEditorOwnerResponse,
  type EditorLabelCommit,
} from "../apps/service/src/editor-owner-envelope.ts";
import { confirmEditorWriterExit } from "../apps/service/src/editor-owner-exit.ts";
const profileId = "10000000-0000-0000-0000-000000000001",
  controlId = "ce000000-0000-0000-0000-000000000001";
const id = "11111111-0000-0000-0000-000000000001";
const executable = resolve(
    import.meta.dir,
    "../native/receiver/target/debug/thumble-rewrite-receiver",
  ),
  cli = resolve(import.meta.dir, "../apps/cli/src/main.ts");
const envelope = (ownerLifetimeId = id): EditorLabelCommit => ({
  command: "editor-label-commit",
  ownerLifetimeId,
  eventId: "event-1",
  authorityInstanceId: id,
  phoneId: "phone-a",
  credentialEpoch: "1",
  intent: {
    command: "configuration-set-control-label",
    operationId: "edit-one",
    expectedRevision: "1",
    profileId,
    controlId,
    label: "Jump",
  },
});
async function stop(owner: ConfigurationOwner) {
  owner.disconnect();
  await confirmEditorWriterExit(owner.child);
}
function pipe(mode: string) {
  return new NativePipe(
    process.execPath,
    [resolve(import.meta.dir, "fixtures/editor-pipe-owner.ts"), mode],
    { ready: () => undefined, reply: (v) => v.result },
    "configuration_owner_unavailable",
  );
}
test("private envelope is immutable, label-only and rejects accessors/extras/zero epochs", () => {
  const valid = decodeEditorLabelCommit(envelope());
  expect(Object.isFrozen(valid)).toBe(true);
  expect(Object.isFrozen(valid.intent)).toBe(true);
  for (const invalid of [
    { ...envelope(), credentialEpoch: "0" },
    { ...envelope(), extra: true },
    { ...envelope(), intent: { command: "configuration-list" } },
    Object.defineProperty({ ...envelope() }, "phoneId", {
      get() {
        throw Error("must_not_run");
      },
    }),
  ])
    expect(() => decodeEditorLabelCommit(invalid)).toThrow();
  for (const key of [
    "eventId",
    "phoneId",
    "credentialEpoch",
    "ownerLifetimeId",
  ] as const)
    expect(() =>
      decodeEditorOwnerResponse(
        {
          envelope: {
            ...valid,
            [key]:
              key === "credentialEpoch"
                ? "2"
                : key === "ownerLifetimeId"
                  ? "22222222-0000-0000-0000-000000000002"
                  : "other",
          },
          outcome: { version: 1, kind: "conflict", currentRevision: "2" },
        },
        valid,
      ),
    ).toThrow("editor_response_mismatch");
});
test("parsed owner errors stay distinct from uncertain EOF/timeout and undispatched requests", async () => {
  const actual = pipe("error"),
    eof = pipe("exit"),
    silent = pipe("silent");
  try {
    expect(await actual.requestParsed({})).toEqual({
      kind: "owner-response",
      ok: false,
      error: "configuration_owner_unavailable",
    });
    expect(await actual.requestParsed({}, 0)).toEqual({
      kind: "not-dispatched",
      error: "native_request_budget_invalid",
    });
    await expect(eof.requestParsed({}, 1000)).rejects.toBeInstanceOf(
      NativePipeTransportLost,
    );
    await expect(silent.requestParsed({}, 30)).rejects.toBeInstanceOf(
      NativePipeTransportLost,
    );
    expect(await silent.requestParsed({})).toEqual({
      kind: "not-dispatched",
      error: "configuration_owner_unavailable",
    });
  } finally {
    for (const p of [actual, eof, silent]) {
      p.disconnect();
      await confirmEditorWriterExit(p.child);
    }
  }
});
test("actual child lifetime binds label receipt and cannot retarget replacement owner", async () => {
  const parent = realpathSync(
      mkdtempSync(join(tmpdir(), "thumble-editor-owner-")),
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
  seed.close();
  let owner = new ConfigurationOwner(executable, directory, [
    process.execPath,
    cli,
  ]);
  try {
    const lifetime = await owner.editorOwnerLifetime(),
      request = envelope(lifetime);
    const result = await owner.commitEditorLabel(request);
    expect(result.kind).toBe("owner-response");
    if (result.kind !== "owner-response") throw Error("test_result");
    expect(result.response.outcome.kind).toBe("committed");
    const replay = await owner.commitEditorLabel(request);
    if (
      replay.kind !== "owner-response" ||
      replay.response.outcome.kind !== "committed"
    )
      throw Error("test_replay");
    expect(replay.response.outcome.replayed).toBe(true);
    const old = owner;
    await stop(old);
    owner = new ConfigurationOwner(executable, directory, [
      process.execPath,
      cli,
    ]);
    expect(await owner.editorOwnerLifetime()).not.toBe(lifetime);
    expect(await owner.commitEditorLabel(request)).toEqual({
      kind: "not-dispatched",
      error: "editor_owner_lifetime_mismatch",
    });
    expect(await old.commitEditorLabel(request)).toEqual({
      kind: "not-dispatched",
      error: "editor_owner_unavailable",
    });
    const listing = await owner.request({
      command: "configuration-list",
      expectedRevision: null,
      offset: 0,
    });
    expect(listing.kind === "catalog" && listing.revision).toBe("2");
  } finally {
    await stop(owner);
    rmSync(parent, { recursive: true, force: true });
  }
}, 15000);
test("writer death confirmation does not accept kill issuance or timeout", async () => {
  const fake = Object.assign(new EventEmitter(), {
    exitCode: null,
    signalCode: null,
    kill: () => true,
  }) as unknown as ChildProcessWithoutNullStreams;
  await expect(confirmEditorWriterExit(fake)).rejects.toThrow(
    "editor_writer_exit_unconfirmed",
  );
  expect(fake.listenerCount("exit")).toBe(0);
  const confirmation = confirmEditorWriterExit(fake);
  fake.emit("exit", 0, null);
  await confirmation;
});

test("dispatch remains exclusive until actual writer exit, with unknown disposition on loss", async () => {
  const owner = new ConfigurationOwner(executable, "/unused", [
    process.execPath,
    resolve(import.meta.dir, "fixtures/editor-pipe-owner.ts"),
    "owner-silent",
  ]);
  await owner.ready;
  const request = envelope(await owner.editorOwnerLifetime());
  const pending = owner.commitEditorLabel(request);
  await new Promise((resolve) => setTimeout(resolve, 20));
  await expect(
    owner.request({
      command: "configuration-list",
      expectedRevision: null,
      offset: 0,
    }),
  ).rejects.toThrow("configuration_owner_busy");
  expect(await owner.commitEditorLabel(request)).toEqual({
    kind: "not-dispatched",
    error: "configuration_owner_busy",
  });
  owner.disconnect();
  expect(await pending).toEqual({
    kind: "writer-exited",
    disposition: "unknown",
  });
  expect(owner.child.exitCode !== null || owner.child.signalCode !== null).toBe(
    true,
  );
  expect(await owner.commitEditorLabel(request)).toEqual({
    kind: "not-dispatched",
    error: "editor_owner_unavailable",
  });
});
test("a malformed correlated reply closes old dispatch and requires actual exit", async () => {
  const owner = new ConfigurationOwner(executable, "/unused", [
    process.execPath,
    resolve(import.meta.dir, "fixtures/editor-pipe-owner.ts"),
    "owner-corrupt",
  ]);
  const result = await owner.commitEditorLabel(
    envelope(await owner.editorOwnerLifetime()),
  );
  expect(result).toEqual({ kind: "writer-exited", disposition: "unknown" });
  expect(owner.child.exitCode !== null || owner.child.signalCode !== null).toBe(
    true,
  );
});
test("legacy readonly owners cannot admit private editor writes", async () => {
  const owner = new ConfigurationOwner(executable, "/unused", [
    process.execPath,
    resolve(import.meta.dir, "fixtures/slow-catalog-owner.ts"),
  ]);
  try {
    await owner.ready;
    expect(await owner.commitEditorLabel(envelope())).toEqual({
      kind: "not-dispatched",
      error: "editor_owner_unavailable",
    });
  } finally {
    await stop(owner);
  }
});

test("actual child rejects queued old-owner bytes before label source or receipt mutation", async () => {
  const parent = realpathSync(
      mkdtempSync(join(tmpdir(), "thumble-editor-queued-")),
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
  seed.close();
  const child = new NativePipe(
    process.execPath,
    [
      cli,
      "__configuration",
      "run",
      "--runtime-dir",
      directory,
      "--receiver",
      executable,
    ],
    { ready: (v) => v.ownerLifetimeId, reply: (v) => v.result },
    "configuration_owner_unavailable",
  );
  try {
    expect(await child.ready).not.toBe(id);
    expect(await child.requestParsed(envelope(id))).toEqual({
      kind: "owner-response",
      ok: false,
      error: "editor_owner_lifetime_mismatch",
    });
    const result = (await child.request({
      command: "configuration-list",
      expectedRevision: null,
      offset: 0,
    })) as { kind: string; revision: string };
    expect(result.kind).toBe("catalog");
    expect(result.revision).toBe("1");
  } finally {
    child.disconnect();
    await confirmEditorWriterExit(child.child);
  }
  const reopened = new SqliteConfigurationRepository(directory, executable);
  try {
    expect(reopened.current()?.revision).toBe("1");
    expect(reopened.receipt("edit-one", "a".repeat(64))).toBeUndefined();
  } finally {
    reopened.close();
    rmSync(parent, { recursive: true, force: true });
  }
});
