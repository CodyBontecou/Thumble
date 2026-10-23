import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  decodeEditorReadCommand,
  decodeEditorProfilePage,
} from "@thumble/contracts/editor-read";
import type { ConfigurationSetControlLabelCommand } from "@thumble/contracts/control-label";
import { projectOwnedEditorProfilePage } from "@thumble/domain/owned-editor-profile";
import { OwnedAuthorityDocument } from "@thumble/domain/owned-authority";
import { starterConfiguration } from "@thumble/domain/starter-configuration";
import { ConfigurationEditorReads } from "@thumble/application/configuration-editor-read";
import { ConfigurationCatalogOperations } from "@thumble/application/configuration-catalog";
import { SqliteConfigurationRepository } from "@thumble/storage";
import { LosslessJson } from "@thumble/contracts/json";

const profileId = "e1000000-0000-0000-0000-000000000001";
const digest = (text: string | Uint8Array) =>
  createHash("sha256").update(text).digest("hex");
const source = starterConfiguration(profileId, "Editor", "1").set(
  "/opaque",
  '{"exact":9007199254740993.000}',
);
const query = {
  command: "editor-profile" as const,
  expectedRevision: "1",
  expectedSourceHash: "a".repeat(64),
  profileId,
  offset: 0,
};
const executable = resolve(
  import.meta.dir,
  "../native/receiver/target/debug/thumble-rewrite-receiver" +
    (process.platform === "win32" ? ".exe" : ""),
);

test("editor pages preserve stable source order, generated labels and exact blank/clear distinctions without materializing assets", () => {
  const firstId = source.get(
    "/profiles/0/customization/elements/0/id",
  )!.stringValue!;
  const secondId = source.get(
    "/profiles/0/customization/elements/1/id",
  )!.stringValue!;
  const edited = source.set(
    "/profiles/0/customization/labelOverrides",
    JSON.stringify({ [firstId]: "", [secondId]: "User" }),
  );
  const before = edited.text();
  const pages = [0, 8, 16].map((offset) =>
    projectOwnedEditorProfilePage(edited, { ...query, offset }),
  );
  expect(pages.map((p) => p.controls.length)).toEqual([8, 8, 2]);
  expect(pages.map((p) => p.nextOffset)).toEqual([8, 16, null]);
  expect(pages[0]!.controls[0]!.labelOverride).toBe("");
  expect(pages[0]!.controls[1]!.labelOverride).toBe("User");
  expect(pages[0]!.controls[2]!.labelOverride).toBeNull();
  expect(pages.flatMap((p) => p.controls.map((c) => c.id))).toEqual(
    Array.from({ length: 18 }, (_, i) =>
      edited
        .get(`/profiles/0/customization/elements/${i}/id`)!
        .stringValue!.toLowerCase(),
    ),
  );
  expect(edited.text()).toBe(before);
  const external = OwnedAuthorityDocument.prepare(edited, digest);
  expect(
    projectOwnedEditorProfilePage(external.document.source, query),
  ).toEqual(pages[0]!);
  expect(() =>
    projectOwnedEditorProfilePage(edited, { ...query, offset: 24 }),
  ).toThrow();
  expect(() =>
    projectOwnedEditorProfilePage(
      edited.set(
        "/profiles/0/customization/elements/17/label",
        JSON.stringify("x".repeat(129)),
      ),
      query,
    ),
  ).toThrow();
});

test("editor boundary rejects getters, coercions, unknown fields, sparse pages and invalid Unicode with a bounded worst-case page", () => {
  let invoked = false;
  expect(() =>
    decodeEditorReadCommand({
      ...query,
      get expectedRevision() {
        invoked = true;
        return "1";
      },
    }),
  ).toThrow();
  expect(invoked).toBe(false);
  for (const value of [
    { ...query, offset: "0" },
    { ...query, offset: 1 },
    { ...query, offset: 128 },
    { ...query, extra: true },
    { ...query, expectedRevision: "01" },
    { ...query, expectedSourceHash: "A".repeat(64) },
  ])
    expect(() => decodeEditorReadCommand(value)).toThrow();
  const page = projectOwnedEditorProfilePage(source, query);
  const worst = {
    ...page,
    name: "\u0000".repeat(255) + "A",
    controls: page.controls.map((c) => ({
      ...c,
      generatedLabel: "\u0000".repeat(128),
      labelOverride: "\u0000".repeat(128),
    })),
  };
  expect(decodeEditorProfilePage(worst)).toEqual(worst);
  expect(new TextEncoder().encode(JSON.stringify(worst)).length).toBeLessThan(
    16384,
  );
  expect(() =>
    decodeEditorProfilePage({ ...page, controls: new Array(8) }),
  ).toThrow();
  const controls = [...page.controls];
  Object.defineProperty(controls, "0", {
    get() {
      invoked = true;
      return page.controls[0];
    },
  });
  expect(() => decodeEditorProfilePage({ ...page, controls })).toThrow();
  expect(invoked).toBe(false);
  expect(() => decodeEditorProfilePage({ ...page, name: "\ud800" })).toThrow();
  expect(() => decodeEditorProfilePage({ ...page, nextOffset: 16 })).toThrow();
  expect(() =>
    decodeEditorProfilePage({
      ...page,
      controls: page.controls.map((c) => ({ ...c, id: page.controls[0]!.id })),
    }),
  ).toThrow();
});

test("actual SQLite editor reads pin revision/hash and reconcile exact prior label intent without source decoding or mutation", () => {
  const root = realpathSync(
    mkdtempSync(join(tmpdir(), "thumble-editor-read-")),
  );
  const repository = new SqliteConfigurationRepository(
    join(root, "runtime"),
    executable,
  );
  const access = { read: true, write: true };
  try {
    repository.commit({
      operationId: "seed",
      payloadHash: "a".repeat(64),
      expectedRevision: "0",
      source,
      affectedEntities: [profileId],
    });
    const reads = new ConfigurationEditorReads(repository, digest);
    const current = repository.current()!;
    const pinned = { ...query, expectedSourceHash: current.contentHash };
    expect(reads.execute(pinned, { read: true, write: false }).kind).toBe(
      "editor-profile",
    );
    expect(() =>
      reads.execute({ ...pinned, expectedRevision: "0" }, access),
    ).toThrow("configuration_revision_conflict");
    expect(() =>
      reads.execute({ ...pinned, expectedSourceHash: "b".repeat(64) }, access),
    ).toThrow("configuration_source_changed");
    expect(() => reads.execute(pinned, { read: false, write: true })).toThrow(
      "configuration_access_denied",
    );
    const intent: ConfigurationSetControlLabelCommand = {
      command: "configuration-set-control-label",
      operationId: "journal-label",
      expectedRevision: "1",
      profileId,
      controlId: source.get("/profiles/0/customization/elements/0/id")!
        .stringValue!,
      label: "",
    };
    expect(
      reads.execute({ command: "editor-label-status", intent }, access),
    ).toEqual({
      version: 1,
      kind: "editor-label-pending",
      operationId: intent.operationId,
    });
    expect(repository.current()!.revision).toBe("1");
    const writes = new ConfigurationCatalogOperations(
      repository,
      digest,
      () => "2",
    );
    const reply = writes.execute(intent, access);
    expect(reply.kind).toBe("committed");
    if (reply.kind !== "committed") throw Error("missing_receipt");
    expect(
      reads.execute({ command: "editor-label-status", intent }, access),
    ).toEqual({
      version: 1,
      kind: "editor-label-receipt",
      receipt: reply.receipt,
    });
    expect(() =>
      reads.execute(
        { command: "editor-label-status", intent: { ...intent, label: null } },
        access,
      ),
    ).toThrow("operation_id_reused");
    repository.commit({
      operationId: "invalid-later",
      payloadHash: "c".repeat(64),
      expectedRevision: "2",
      source: LosslessJson.parse('{"unknown":true}'),
      affectedEntities: [],
    });
    expect(
      reads.execute({ command: "editor-label-status", intent }, access),
    ).toEqual({
      version: 1,
      kind: "editor-label-receipt",
      receipt: reply.receipt,
    });
    expect(repository.current()!.revision).toBe("3");
    expect(reply.receipt.affectedEntities).toEqual([
      profileId,
      intent.controlId,
    ]);
  } finally {
    repository.close();
    rmSync(root, { recursive: true, force: true });
  }
});
