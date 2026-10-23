import { wowLiveChecksum } from "@thumble/domain/wow-live";
import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { ConfigurationWowOperations } from "../apps/service/src/configuration-wow.ts";
import { WowCaptureSession } from "../apps/service/src/wow-capture-session.ts";
import { decodeWowAtlas } from "../apps/service/src/wow-atlas-decoder.ts";
import { atlasPNGFixture } from "./fixtures/wow-atlas-fixture.ts";
import { starterConfiguration } from "@thumble/domain/starter-configuration";
import { LosslessJson } from "@thumble/contracts/json";
import { configurationSourceHash } from "@thumble/storage";
import {
  ConfigurationRevisionConflict,
  type ConfigurationRepository,
  type ConfigurationCommit,
  type ConfigurationSource,
} from "@thumble/application/configuration-store";
import type { ConfigurationReceipt } from "@thumble/contracts/configuration";
import type { WowProfilePreparer } from "@thumble/application/wow-profile-refresh";
import {
  decodeWowSyncCommand,
  decodeWowSyncStatus,
  disabledWowSyncStatus,
} from "@thumble/contracts/wow-sync-control";
const fixture = JSON.parse(
  readFileSync(
    resolve(import.meta.dir, "../packages/fixtures/wow-live-v1.json"),
    "utf8",
  ),
);
class Repository implements ConfigurationRepository {
  value: ConfigurationSource | undefined;
  commits = 0;
  conflict = false;
  current() {
    return this.value;
  }
  receipt() {
    return undefined;
  }
  commit(command: ConfigurationCommit): {
    receipt: ConfigurationReceipt;
    replayed: boolean;
  } {
    if (
      this.conflict ||
      command.expectedRevision !== (this.value?.revision ?? "0")
    )
      throw new ConfigurationRevisionConflict(this.value?.revision ?? "0");
    this.commits++;
    this.value = {
      revision: String(this.commits),
      contentHash: configurationSourceHash(command.source),
      source: command.source,
    };
    return {
      replayed: false,
      receipt: {
        version: 1,
        operationId: command.operationId,
        resultingRevision: this.value.revision,
        contentHash: this.value.contentHash,
        affectedEntities: command.affectedEntities,
      },
    };
  }
}
function liveFrame(index: number): Uint8Array {
  const bytes = Uint8Array.from(
    Buffer.from(fixture.frames[index % fixture.frames.length], "hex"),
  );
  const view = new DataView(bytes.buffer);
  view.setUint32(5, 123 + index, true);
  const data = new Uint8Array(21 + view.getUint16(17, true));
  data.set(bytes.subarray(0, 21));
  data.set(bytes.subarray(25, 25 + data.length - 21), 21);
  view.setUint32(21, wowLiveChecksum(data), true);
  return bytes;
}
function harness() {
  let frames = 0,
    stops = 0,
    calls = 0;
  let delay: Promise<void> | undefined;
  let release: (() => void) | undefined;
  const capture = new WowCaptureSession({
    clock: () => Math.floor(performance.now()),
    schedule: (ms, cb) => {
      const timer = setTimeout(cb, ms);
      return () => clearTimeout(timer);
    },
    decodeAtlas: decodeWowAtlas,
    create: () => ({
      capture: async (text) =>
        JSON.stringify({
          ...JSON.parse(text),
          command: "wow-capture-result",
          kind: "frame",
          frameBase64: Buffer.from(liveFrame(frames++)).toString("base64"),
          atlasPNGBase64: atlasPNGFixture().toString("base64"),
        }),
      stop: async () => {
        stops++;
      },
    }),
  });
  const preparer: WowProfilePreparer = {
    async prepare(request) {
      calls++;
      await delay;
      const snapshot = JSON.parse(request.snapshotJSON);
      const document = starterConfiguration(
        request.profileID,
        "Synthetic WoW",
        "1",
      ).set(
        "/profiles/0/wowLive",
        JSON.stringify({
          characterID: snapshot.character.id,
          flavor: snapshot.client.flavor,
        }),
      );
      const correlated = document.set(
        "/profiles",
        `[${request.existingProfileJSON}]`,
      );
      return {
        schemaVersion: 2,
        sourceSHA256: createHash("sha256")
          .update(request.existingProfileJSON!)
          .digest("hex"),
        beforeProfile: LosslessJson.parse(request.existingProfileJSON!),
        document: correlated,
      };
    },
  };
  const repository = new Repository();
  const published: unknown[] = [];
  const wow = new ConfigurationWowOperations({
    repository,
    capture,
    preparer,
    readAsset: () => {
      throw Error("unexpected_asset");
    },
    publish: (capture, sync) => published.push({ capture, sync }),
  });
  return {
    wow,
    repository,
    published,
    get calls() {
      return calls;
    },
    get stops() {
      return stops;
    },
    pause() {
      delay = new Promise<void>((r) => (release = r));
      return () => release?.();
    },
  };
}
async function until(condition: () => boolean) {
  const end = Date.now() + 3000;
  while (!condition() && Date.now() < end) await Bun.sleep(5);
  expect(condition()).toBe(true);
}
const command = {
  command: "wow-refresh",
  operationId: "refresh-one",
  expectedRevision: "0",
  expectedSourceHash: null,
} as const;
test("one child-owned manual optical refresh commits exact atlas/snapshot pipeline; duplicate job does not dispatch", async () => {
  const h = harness();
  try {
    expect(h.wow.execute(command).busy).toBe(true);
    await until(() => !h.wow.busy);
    const status = decodeWowSyncStatus(h.wow.status());
    expect(status.state).toBe("ready");
    expect(status.lastOutcome).toBe("committed");
    expect(status.acknowledged).toBe(true);
    expect(h.repository.commits).toBe(1);
    expect(h.calls).toBe(1);
    expect(h.stops).toBe(1);
    expect(h.wow.execute(command)).toEqual(status);
    expect(h.calls).toBe(1);
    expect(() =>
      h.wow.execute({ ...command, command: "wow-sync-start" }),
    ).toThrow("operation_id_reused");
    expect(JSON.stringify(h.published)).not.toContain("Base64");
    expect(JSON.stringify(h.published)).not.toContain("snapshotJSON");
  } finally {
    await h.wow.close();
  }
}, 5000);
test("conflicting commit never ACKs and explicit stop cancels a delayed prepared update before CAS", async () => {
  const h = harness();
  h.repository.conflict = true;
  try {
    h.wow.execute(command);
    await until(() => !h.wow.busy);
    expect(h.wow.status().state).toBe("conflict");
    expect(h.repository.commits).toBe(0);
    expect(h.wow.status().acknowledged).toBeNull();
  } finally {
    await h.wow.close();
  }
  const stopped = harness(),
    resume = stopped.pause();
  try {
    stopped.wow.execute(command);
    await until(() => stopped.calls === 1);
    expect(
      stopped.wow.execute({
        command: "wow-sync-stop",
        operationId: command.operationId,
      }).state,
    ).toBe("stopping");
    resume();
    await until(() => !stopped.wow.busy);
    expect(stopped.repository.commits).toBe(0);
    expect(stopped.wow.status().state).toBe("stopped");
  } finally {
    resume();
    await stopped.wow.close();
  }
}, 5000);
test("sync command/status rejects arbitrary executables, coerced fields and mismatched review identity", () => {
  expect(decodeWowSyncStatus(disabledWowSyncStatus()).state).toBe("disabled");
  for (const value of [
    { ...command, path: "private" },
    { ...command, expectedRevision: "1" },
    { ...command, operationId: "" },
    { ...command, expectedSourceHash: "a".repeat(64) },
  ])
    expect(() => decodeWowSyncCommand(value)).toThrow();
  for (const patch of [
    { state: ["disabled"] },
    { lastOutcome: ["none"] },
    { busy: "false" },
    { error: "raw-secret" },
    { extra: true },
  ])
    expect(() =>
      decodeWowSyncStatus({ ...disabledWowSyncStatus(), ...patch }),
    ).toThrow();
  let reads = 0;
  const getter = Object.defineProperty(
    { ...disabledWowSyncStatus() },
    "state",
    {
      get() {
        reads++;
        return "disabled";
      },
    },
  );
  expect(() => decodeWowSyncStatus(getter)).toThrow();
  expect(reads).toBe(0);
  const h = harness();
  expect(() =>
    h.wow.execute({
      ...command,
      expectedRevision: "1",
      expectedSourceHash: "a".repeat(64),
    }),
  ).toThrow("configuration_revision_conflict");
});

test("live pipeline has one pending observation, deduplicates unchanged advancing messages and bounds ephemeral job history", async () => {
  const h = harness();
  try {
    h.wow.execute({ ...command, command: "wow-sync-start" });
    await until(() => h.repository.commits === 1);
    await Bun.sleep(420);
    expect(h.wow.status().state).toBe("running");
    expect(h.calls).toBe(1);
    expect(h.repository.commits).toBe(1);
    const applied = h.wow.status();
    expect(
      h.wow.presentationFreshness(
        applied.profileId!,
        applied.revision!,
        applied.contentHash!,
      ),
    ).toBe("observed");
    expect(
      h.wow.presentationFreshness(
        applied.profileId!,
        applied.revision!,
        "a".repeat(64),
      ),
    ).toBe("stale");
    expect(h.wow.presentationFreshness("unknown", "1", "a".repeat(64))).toBe(
      "not-evaluated",
    );
    h.wow.execute({
      command: "wow-sync-stop",
      operationId: command.operationId,
    });
    await until(() => !h.wow.busy);
    expect(
      h.wow.presentationFreshness(
        applied.profileId!,
        applied.revision!,
        applied.contentHash!,
      ),
    ).toBe("stale");
  } finally {
    await h.wow.close();
  }
  const bounded = harness();
  try {
    for (let i = 0; i < 33; i++) {
      const operationId = `bounded-${i}`;
      bounded.wow.execute({
        ...command,
        command: "wow-sync-start",
        operationId,
      });
      bounded.wow.execute({ command: "wow-sync-stop", operationId });
      await until(() => !bounded.wow.busy);
    }
    expect(() =>
      bounded.wow.execute({
        command: "wow-sync-status",
        operationId: "bounded-0",
      }),
    ).toThrow("wow_sync_unknown");
    expect(
      bounded.wow.execute({
        command: "wow-sync-status",
        operationId: "bounded-32",
      }).state,
    ).toBe("stopped");
    expect(bounded.repository.commits).toBe(0);
  } finally {
    await bounded.wow.close();
  }
}, 5000);
