import { LosslessJson } from "@thumble/contracts/json";
import { ConfigurationSavedPinOperations } from "@thumble/application/configuration-saved-pin";
import type {
  ConfigurationSource,
  ConfigurationRepository,
} from "@thumble/application/configuration-store";
import { configurationSourceHash } from "@thumble/storage";
import { expect, test } from "bun:test";
import { readFileSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  decodeSavedRuntimeCommand,
  decodeSavedConfigurationPin,
  decodeSavedBinding,
} from "@thumble/contracts/saved-runtime";
import { decodeSnapshot } from "@thumble/contracts/receiver";
const root = resolve(import.meta.dir, "..");
test("saved binding contracts reject loose source identity and unrelated native epochs", () => {
  const pin = {
    configurationRevision: "7",
    sourceHash: "a".repeat(64),
    profileId: "aaaaaaaa-0000-0000-0000-000000000001",
  };
  expect(decodeSavedConfigurationPin(pin)).toEqual(pin);
  for (const patch of [
    { configurationRevision: "0" },
    { configurationRevision: "01" },
    { sourceHash: "A".repeat(64) },
    { sourceHash: "unknown" },
    { profileId: "profile-label" },
    { credential: "private" },
  ])
    expect(() => decodeSavedConfigurationPin({ ...pin, ...patch })).toThrow();
  const command = {
    command: "activate-saved",
    expectedReceiverRevision: "2",
    expectedConfigurationRevision: "7",
    expectedSourceHash: pin.sourceHash,
    profileId: pin.profileId,
  };
  expect(decodeSavedRuntimeCommand(command).command).toBe("activate-saved");
  expect(() =>
    decodeSavedRuntimeCommand({ ...command, activate: true }),
  ).toThrow();
  const snapshot = decodeSnapshot({
    backend: "recording",
    inputEnabled: false,
    active: true,
    generation: "3",
    revision: "3",
    profileId: pin.profileId,
    sequence: null,
    reportHex: "0014000000000000000000000000000000000000",
    lastReleaseReason: "activation_barrier",
  });
  expect(
    decodeSavedBinding({ ...pin, generation: "3", revision: "3" }, snapshot)
      ?.sourceHash,
  ).toBe(pin.sourceHash);
  expect(() =>
    decodeSavedBinding({ ...pin, generation: "2", revision: "3" }, snapshot),
  ).toThrow("saved_runtime_binding_mismatch");
  expect(() =>
    decodeSavedBinding(
      { ...pin, generation: "3", revision: "3" },
      { ...snapshot, active: false },
    ),
  ).toThrow("saved_runtime_binding_mismatch");
});
test("real CLI service and both MCP SDK eras bind exact saved authority to native recording generations", async () => {
  const parent = realpathSync(
    mkdtempSync(join(tmpdir(), "thumble-saved-activation-")),
  );
  try {
    const child = Bun.spawn(
      [
        "node",
        join(root, "tooling/test-saved-activation-node.mjs"),
        process.execPath,
        join(root, "apps/cli/src/main.ts"),
        join(
          root,
          `native/receiver/target/debug/thumble-rewrite-receiver${process.platform === "win32" ? ".exe" : ""}`,
        ),
        join(parent, "runtime"),
        join(root, "packages/fixtures/owned-configuration-v1/document.json"),
      ],
      { stdout: "pipe", stderr: "pipe" },
    );
    const [out, err, code] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited,
    ]);
    expect(err).toBe("");
    expect(code).toBe(0);
    expect(JSON.parse(out)).toEqual({
      ok: true,
      scenarios: 4,
      recordingOnly: true,
      server: "source",
    });
  } finally {
    rmSync(parent, { recursive: true, force: true });
  }
}, 30000);
test("sole-writer saved pin validates observed revision/hash/selection and never commits", () => {
  const source = LosslessJson.parse(
    readFileSync(
      join(root, "packages/fixtures/owned-configuration-v1/document.json"),
      "utf8",
    ),
  );
  let current: ConfigurationSource | undefined = {
    source,
    revision: "7",
    contentHash: configurationSourceHash(source),
  };
  const repository: ConfigurationRepository = {
    current: () => current,
    receipt: () => undefined,
    commit: () => {
      throw new Error("read must not commit");
    },
  };
  const operation = new ConfigurationSavedPinOperations(
    repository,
    configurationSourceHash,
  );
  const command = {
    command: "configuration-saved-pin",
    expectedRevision: "7",
    expectedSourceHash: current.contentHash,
    profileId: "ea000000-0000-0000-0000-000000000001",
  } as const;
  const pin = operation.execute(command);
  expect(pin.sourceHash).toBe(current.contentHash);
  expect(pin.configurationRevision).toBe("7");
  expect(() =>
    operation.execute({ ...command, expectedRevision: "8" }),
  ).toThrow("configuration_revision_conflict");
  expect(() =>
    operation.execute({ ...command, expectedSourceHash: "0".repeat(64) }),
  ).toThrow("configuration_source_changed");
  expect(() =>
    operation.execute({
      ...command,
      profileId: "ffffffff-0000-0000-0000-000000000001",
    }),
  ).toThrow("saved_profile_not_selected");
  current = { ...current, source: source.set("/opaquePinnedSource", "true") };
  expect(() => operation.execute(command)).toThrow(
    "configuration_source_changed",
  );
  current = undefined;
  expect(() => operation.execute(command)).toThrow("configuration_empty");
});
