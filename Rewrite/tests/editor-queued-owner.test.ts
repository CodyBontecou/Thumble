import { expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { ConfigurationOwner } from "../apps/service/src/configuration-owner.ts";
import { confirmEditorWriterExit } from "../apps/service/src/editor-owner-exit.ts";
import type { EditorLabelCommit } from "../apps/service/src/editor-owner-envelope.ts";
const id = "11111111-0000-0000-0000-000000000001";
const envelope: EditorLabelCommit = {
  command: "editor-label-commit",
  ownerLifetimeId: id,
  eventId: "1",
  authorityInstanceId: id,
  phoneId: "phone-a",
  credentialEpoch: "1",
  intent: {
    command: "configuration-set-control-label",
    operationId: "queued-label",
    expectedRevision: "1",
    profileId: "10000000-0000-0000-0000-000000000001",
    controlId: "ce000000-0000-0000-0000-000000000001",
    label: "Jump",
  },
};
for (const retire of [false, true])
  test(`reserved editor write ${retire ? "retires without dispatch" : "waits for existing CLI read and keeps captured owner"}`, async () => {
    const directory = mkdtempSync(join(tmpdir(), "editor-turn-"));
    const owner = new ConfigurationOwner("/unused", directory, [
      "node",
      resolve(import.meta.dir, "fixtures/editor-queued-owner.mjs"),
    ]);
    let dispatched = 0;
    let started!: () => void;
    const readStarted = new Promise<void>((resolve) => (started = resolve));
    owner.child.stderr.on("data", (chunk) => {
      if (chunk.toString().includes("read-started")) started();
      if (chunk.toString().includes("editor-dispatched")) dispatched++;
    });
    try {
      await owner.ready;
      const read = owner
        .request({
          command: "configuration-list",
          expectedRevision: null,
          offset: 0,
        })
        .then(
          () => "unexpected",
          (e: Error) => e.message,
        );
      await readStarted;
      const write = owner.commitEditorLabel(envelope);
      await new Promise<void>((resolve) => setImmediate(resolve));
      await expect(
        owner.request({
          command: "configuration-list",
          expectedRevision: null,
          offset: 0,
        }),
      ).rejects.toThrow("configuration_owner_busy");
      expect(dispatched).toBe(0);
      if (retire) {
        await owner.retireEditorOwner();
        expect(await write).toEqual({
          kind: "writer-exited",
          disposition: "unknown",
        });
        expect(dispatched).toBe(0);
      } else {
        writeFileSync(join(directory, "release"), "");
        expect(await read).toBe("configuration_conflict");
        expect(await write).toEqual({
          kind: "owner-error",
          error: "configuration_conflict",
        });
        expect(dispatched).toBe(1);
        expect(await owner.editorOwnerLifetime()).toBe(id);
        expect(
          await owner.commitEditorLabel({ ...envelope, eventId: "2" }),
        ).toEqual({ kind: "owner-error", error: "configuration_conflict" });
      }
      await read;
    } finally {
      owner.disconnect();
      await confirmEditorWriterExit(owner.child);
      rmSync(directory, { recursive: true, force: true });
    }
  });
