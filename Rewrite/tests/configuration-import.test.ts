import { expect, test } from "bun:test";
import { createHash, randomUUID } from "node:crypto";
import {
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { once } from "node:events";
import { LosslessJson } from "@thumble/contracts/json";
import {
  decodeConfigurationCommand,
  decodeConfigurationReply,
  type ConfigurationImportFileCommand,
  type ConfigurationReply,
} from "@thumble/contracts/configuration";
import { ConfigurationImportOperations } from "@thumble/application/configuration-import";
import { OwnedAuthorityDocument } from "@thumble/domain/owned-authority";
import {
  SqliteConfigurationRepository,
  configurationSourceHash,
} from "@thumble/storage";
import { FileAssetStore } from "@thumble/storage/asset-files";
import { readConfigurationFile } from "@thumble/client/local";
import { ConfigurationOwner } from "../apps/service/src/configuration-owner.ts";
import { NativeReceiver } from "../apps/service/src/native-receiver.ts";
import { RuntimeController } from "@thumble/application";
import { neutralGamepadState } from "@thumble/contracts";
import { expectError } from "./helpers/rejection.ts";
const root = resolve(import.meta.dir, ".."),
  cli = resolve(root, "apps/cli/src/main.ts"),
  executable = resolve(
    root,
    `native/receiver/target/debug/thumble-rewrite-receiver${process.platform === "win32" ? ".exe" : ""}`,
  );
const digest = (value: string | Uint8Array) =>
  createHash("sha256").update(value).digest("hex");
const fixtureSource = () =>
  LosslessJson.parse(
    readFileSync(
      resolve(root, "packages/fixtures/owned-configuration-v1/document.json"),
      "utf8",
    ),
  );
const access = { read: true, write: true };
async function fixture(
  run: (parent: string, directory: string) => void | Promise<void>,
) {
  const parent = realpathSync(
    mkdtempSync(join(tmpdir(), "thumble-owned-import-")),
  );
  try {
    await run(parent, join(parent, "runtime"));
  } finally {
    rmSync(parent, { recursive: true, force: true });
  }
}
const intent = (
  path: string,
  source = fixtureSource(),
  operationId = "owned-import",
  expectedRevision = "0",
): ConfigurationImportFileCommand => ({
  command: "configuration-import-file",
  path,
  operationId,
  expectedRevision,
  expectedSourceHash: configurationSourceHash(source),
});
const status = (command: ConfigurationImportFileCommand) =>
  ({
    command: "configuration-import-status",
    operationId: command.operationId,
    expectedRevision: command.expectedRevision,
    expectedSourceHash: command.expectedSourceHash,
  }) as const;
async function close(owner: ConfigurationOwner) {
  const exited =
    owner.child.exitCode !== null || owner.child.signalCode !== null
      ? Promise.resolve()
      : once(owner.child, "exit");
  owner.disconnect();
  const timer = setTimeout(() => owner.child.kill("SIGKILL"), 3000);
  try {
    await exited;
  } finally {
    clearTimeout(timer);
  }
}
async function completed(
  owner: ConfigurationOwner,
  command: ConfigurationImportFileCommand,
): Promise<ConfigurationReply> {
  const deadline = performance.now() + 10000;
  for (;;) {
    const reply = await owner.request(status(command));
    if (reply.kind !== "import-pending") return reply;
    if (performance.now() >= deadline)
      throw new Error("test_import_did_not_finish");
    await Bun.sleep(20);
  }
}

test("owned file import atomically stores assets and exact saved data, with durable retry before file IO", async () =>
  fixture((parent, directory) => {
    const file = join(parent, "owned.json"),
      source = fixtureSource(),
      command = intent(file, source);
    writeFileSync(file, source.text());
    let repository = new SqliteConfigurationRepository(directory, executable);
    const make = () =>
      new ConfigurationImportOperations(repository, {
        readFile: readConfigurationFile,
        digest,
        sourceHash: configurationSourceHash,
        resourceHash: digest,
      });
    try {
      const result = make().execute(command, access);
      expect(result.kind).toBe("import-committed");
      if (result.kind !== "import-committed")
        throw new Error("test_commit_missing");
      expect(decodeConfigurationReply(result, command)).toEqual(result);
      expect(result.receipt.affectedEntities).toEqual(["configuration"]);
      expect(result.receipt.resultingRevision).toBe("1");
      expect(result.activationCompatibility).toBe("not-evaluated");
      const current = repository.current()!,
        authority = OwnedAuthorityDocument.read(current.source),
        assets = new FileAssetStore(directory, executable);
      expect(authority.resources.length).toBeGreaterThan(1);
      expect(
        authority
          .materialize((hash) => assets.read(hash), digest)
          .source.canonicalText(),
      ).toBe(source.canonicalText());
      rmSync(file);
      repository.close();
      repository = new SqliteConfigurationRepository(directory, executable);
      expect(make().execute(command, access)).toEqual({
        ...result,
        replayed: true,
      });
      expect(() =>
        make().execute(
          { ...command, expectedSourceHash: "f".repeat(64) },
          access,
        ),
      ).toThrow("operation_id_reused");
      expect(repository.current()?.revision).toBe("1");
    } finally {
      repository.close();
    }
  }));

test("import capability/CAS/hash/structural failures cannot write a receipt or replace saved authority", async () =>
  fixture((parent, directory) => {
    const file = join(parent, "owned.json"),
      source = fixtureSource(),
      command = intent(file, source);
    const repository = new SqliteConfigurationRepository(directory, executable);
    let reads = 0;
    const imports = new ConfigurationImportOperations(repository, {
      readFile: (path) => {
        reads++;
        return readConfigurationFile(path);
      },
      digest,
      sourceHash: configurationSourceHash,
      resourceHash: digest,
    });
    try {
      for (const denied of [
        { read: false, write: true },
        { read: true, write: false },
      ])
        expect(() => imports.execute(command, denied)).toThrow(
          "configuration_access_denied",
        );
      expect(reads).toBe(0);
      expect(
        imports.execute({ ...command, expectedRevision: "1" }, access),
      ).toEqual({ version: 1, kind: "conflict", currentRevision: "0" });
      expect(reads).toBe(0);
      writeFileSync(
        file,
        source.set("/profiles/0/name", '"Changed after review"').text(),
      );
      expect(() => imports.execute(command, access)).toThrow(
        "configuration_source_changed",
      );
      const malformed = source
        .remove("/profiles/1/customization/customButtons")
        .set(
          "/profiles/1/customization/elements/6/joystickOutputSettings/sensitivity",
          "1e9999",
        );
      writeFileSync(file, malformed.text());
      expect(() => imports.execute(intent(file, malformed), access)).toThrow(
        "invalid_owned_configuration",
      );
      expect(repository.current()).toBeUndefined();
      writeFileSync(file, source.text());
      expect(imports.execute(command, access).kind).toBe("import-committed");
      const replaced = source.set("/profiles/0/name", '"Replacement"');
      writeFileSync(file, replaced.text());
      const result = imports.execute(
        intent(file, replaced, "replace-all", "1"),
        access,
      );
      expect(result.kind).toBe("import-committed");
      expect(
        repository.current()?.source.get("/document/profiles/0/name")
          ?.stringValue,
      ).toBe("Replacement");
      expect(repository.current()?.revision).toBe("2");
    } finally {
      repository.close();
    }
  }));

test(
  "configuration import worker admits one bounded job and recovers its receipt after restart",
  async () =>
    fixture(async (parent, directory) => {
      const file = join(parent, "owned.json"),
        source = fixtureSource()
          .set("/futureRootMetadata/importNumber", "9007199254740993.0000")
          .set(
            "/futureRootMetadata/padding",
            JSON.stringify("x".repeat(131072)),
          ),
        command = intent(file, source);
      writeFileSync(file, source.text());
      let owner = new ConfigurationOwner(executable, directory, [
        process.execPath,
        cli,
      ]);
      try {
        await owner.ready;
        expect(await owner.request(command)).toEqual({
          version: 1,
          kind: "import-pending",
          operationId: command.operationId,
        });
        expect((await owner.request(command)).kind).toMatch(
          /import-pending|import-committed/,
        );
        await expectError(
          owner.request({ ...command, expectedSourceHash: "f".repeat(64) }),
          "operation_id_reused",
        );
        const result = await completed(owner, command);
        expect(result.kind).toBe("import-committed");
        expect(JSON.stringify(result)).not.toContain(file);
        expect(JSON.stringify(result)).not.toContain("Arcade");
        expect(
          (
            await owner.request({
              command: "configuration-list",
              expectedRevision: null,
              offset: 0,
            })
          ).kind,
        ).toBe("catalog");
        await close(owner);
        rmSync(file);
        owner = new ConfigurationOwner(executable, directory, [
          process.execPath,
          cli,
        ]);
        await owner.ready;
        await expectError(
          owner.request(status(command)),
          "configuration_import_unknown",
        );
        expect((await owner.request(command)).kind).toBe("import-pending");
        const replay = await completed(owner, command);
        expect(replay.kind).toBe("import-committed");
        if (replay.kind === "import-committed")
          expect(replay.replayed).toBe(true);
      } finally {
        await close(owner);
      }
    }),
  15000,
);

test.skipIf(process.platform === "win32")(
  "bulk import polls and native input remain responsive while the child exceeds its ordinary request deadline",
  async () =>
    fixture(async (parent, directory) => {
      const file = join(parent, "owned.json"),
        command = intent(file);
      writeFileSync(file, fixtureSource().text());
      const owner = new ConfigurationOwner(executable, directory, [
        process.execPath,
        cli,
      ]);
      const native = new NativeReceiver(
        executable,
        directory,
        join(directory, "recording.jsonl"),
      );
      const controller = new RuntimeController(native, randomUUID);
      let suspended = false;
      try {
        await Promise.all([owner.ready, native.ready]);
        await controller.execute({
          command: "activate",
          expectedRevision: "0",
          profileId: "import-isolation",
        });
        expect(owner.child.kill("SIGSTOP")).toBe(true);
        suspended = true;
        const started = performance.now();
        expect((await owner.request(command)).kind).toBe("import-pending");
        expect(performance.now() - started).toBeLessThan(500);
        await expectError(
          owner.request({ ...command, operationId: "competing" }),
          "configuration_owner_busy",
        );
        await expectError(
          owner.request({
            command: "configuration-list",
            expectedRevision: null,
            offset: 0,
          }),
          "configuration_owner_busy",
        );
        let sequence = 0;
        do {
          await controller.renew();
          expect(
            (
              await controller.execute({
                command: "sample",
                expectedGeneration: "1",
                sequence: String(sequence++),
                state: { ...neutralGamepadState(), buttons: ["south"] },
                allowRecordedInput: true,
              })
            ).active,
          ).toBe(true);
          const poll = performance.now();
          expect((await owner.request(status(command))).kind).toBe(
            "import-pending",
          );
          expect(performance.now() - poll).toBeLessThan(100);
          await Bun.sleep(100);
        } while (performance.now() - started < 2300);
        expect(owner.child.kill("SIGCONT")).toBe(true);
        suspended = false;
        expect((await completed(owner, command)).kind).toBe("import-committed");
        expect((await controller.execute({ command: "status" })).active).toBe(
          true,
        );
      } finally {
        if (suspended) owner.child.kill("SIGCONT");
        try {
          await controller.execute({ command: "stop" });
        } catch {}
        const exited =
          native.child.exitCode !== null || native.child.signalCode !== null
            ? Promise.resolve()
            : once(native.child, "exit");
        native.disconnect();
        await exited;
        await close(owner);
      }
    }),
  15000,
);

test("import contract refuses unbound results, extra fields and activation claims", () => {
  const command = intent("/owned.json");
  for (const bad of [
    { ...command, expectedSourceHash: "bad" },
    { ...command, path: "x\0" },
    { ...command, source: "raw" },
    { ...status(command), path: "/not-allowed" },
  ])
    expect(() => decodeConfigurationCommand(bad)).toThrow();
  const reply = {
    version: 1,
    kind: "import-committed",
    replayed: false,
    validation: "owned-v5-structural",
    activationCompatibility: "not-evaluated",
    receipt: {
      version: 1,
      operationId: command.operationId,
      resultingRevision: "1",
      contentHash: "a".repeat(64),
      affectedEntities: ["configuration"],
    },
  } as const;
  expect(decodeConfigurationReply(reply, command)).toEqual(reply);
  for (const bad of [
    { ...reply, activationCompatibility: "ready" },
    { ...reply, receipt: { ...reply.receipt, resultingRevision: "2" } },
    { ...reply, receipt: { ...reply.receipt, affectedEntities: [] } },
    { ...reply, receipt: { ...reply.receipt, operationId: "other" } },
    {
      version: 1,
      kind: "import-failed",
      operationId: command.operationId,
      error: "/private/path",
    },
    { version: 1, kind: "import-pending", operationId: "other" },
  ])
    expect(() => decodeConfigurationReply(bad, command)).toThrow();
});

test(
  "import job result cache is bounded and failed intents can be retried without exposing paths",
  async () =>
    fixture(async (parent, directory) => {
      const owner = new ConfigurationOwner(executable, directory, [
        process.execPath,
        cli,
      ]);
      const first = intent(
        join(parent, "missing.json"),
        fixtureSource(),
        "failure-0",
      );
      try {
        await owner.ready;
        for (let index = 0; index < 34; index++) {
          const command = { ...first, operationId: `failure-${index}` };
          expect((await owner.request(command)).kind).toBe("import-pending");
          expect(await completed(owner, command)).toEqual({
            version: 1,
            kind: "import-failed",
            operationId: command.operationId,
            error: "configuration_file_unavailable",
          });
        }
        await expectError(
          owner.request(status(first)),
          "configuration_import_unknown",
        );
        writeFileSync(first.path, fixtureSource().text());
        const retry = { ...first, operationId: "failure-33" };
        expect((await owner.request(retry)).kind).toBe("import-pending");
        expect((await completed(owner, retry)).kind).toBe("import-committed");
      } finally {
        await close(owner);
      }
    }),
  15000,
);

test(
  "lost import reply after durable commit fails boundedly and recovers its receipt after restart",
  async () =>
    fixture(async (parent, directory) => {
      const command = intent(join(parent, "owned.json"));
      writeFileSync(command.path, fixtureSource().text());
      let owner = new ConfigurationOwner(executable, directory, [
        process.execPath,
        resolve(import.meta.dir, "fixtures/lost-import-owner.ts"),
      ]);
      try {
        await owner.ready;
        expect((await owner.request(command)).kind).toBe("import-pending");
        const failed = await completed(owner, command);
        expect(failed).toEqual({
          version: 1,
          kind: "import-failed",
          operationId: command.operationId,
          error: "configuration_owner_unavailable",
        });
        await close(owner);
        rmSync(command.path);
        owner = new ConfigurationOwner(executable, directory, [
          process.execPath,
          cli,
        ]);
        await owner.ready;
        await owner.request(command);
        const recovered = await completed(owner, command);
        expect(recovered.kind).toBe("import-committed");
        if (recovered.kind === "import-committed")
          expect(recovered.replayed).toBe(true);
      } finally {
        await close(owner);
      }
    }),
  15000,
);

test(
  "malformed typed import replies terminate the poisoned owner and expose only a bounded failed job",
  async () =>
    fixture(async (parent, directory) => {
      const owner = new ConfigurationOwner(executable, directory, [
        process.execPath,
        resolve(import.meta.dir, "fixtures/invalid-configuration-owner.ts"),
      ]);
      const command = intent(join(parent, "owned.json"));
      try {
        await owner.ready;
        expect((await owner.request(command)).kind).toBe("import-pending");
        expect(await completed(owner, command)).toEqual({
          version: 1,
          kind: "import-failed",
          operationId: command.operationId,
          error: "configuration_response_invalid",
        });
        await close(owner);
        expect(
          owner.child.exitCode !== null || owner.child.signalCode !== null,
        ).toBe(true);
      } finally {
        await close(owner);
      }
    }),
  10000,
);
