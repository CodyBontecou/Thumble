import { expect, test } from "bun:test";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { once } from "node:events";
import { randomUUID } from "node:crypto";
import { SqliteConfigurationRepository } from "@thumble/storage";
import { RuntimeController } from "@thumble/application";
import { neutralGamepadState } from "@thumble/contracts";
import { ConfigurationOwner } from "../apps/service/src/configuration-owner.ts";
import { NativeReceiver } from "../apps/service/src/native-receiver.ts";
import { catalogFixtureSource, a, b } from "./helpers/configuration-fixture.ts";
const root = resolve(import.meta.dir, ".."),
  cli = resolve(root, "apps/cli/src/main.ts");
const executable = resolve(
  root,
  `native/receiver/target/debug/thumble-rewrite-receiver${process.platform === "win32" ? ".exe" : ""}`,
);
const launcher = [process.execPath, cli];
async function fixture(run: (directory: string) => Promise<void>) {
  const parent = realpathSync(
    mkdtempSync(join(tmpdir(), "thumble-config-owner-")),
  );
  try {
    await run(join(parent, "runtime"));
  } finally {
    rmSync(parent, { recursive: true, force: true });
  }
}
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
const list = {
  command: "configuration-list",
  expectedRevision: null,
  offset: 0,
} as const;

test(
  "dedicated configuration process preserves CAS, receipts, exclusive ownership and restart barriers",
  async () =>
    fixture(async (directory) => {
      const seed = new SqliteConfigurationRepository(directory, executable);
      seed.commit({
        operationId: "seed",
        payloadHash: "a".repeat(64),
        expectedRevision: "0",
        source: catalogFixtureSource(),
        affectedEntities: [a, b],
      });
      seed.close();
      let owner = new ConfigurationOwner(executable, directory, launcher);
      const rename = {
        command: "configuration-rename-profile",
        operationId: "rename",
        expectedRevision: "1",
        profileId: a,
        name: "Worker rename 🦊",
      } as const;
      try {
        await owner.ready;
        expect(owner.child.pid).not.toBe(process.pid);
        expect(
          () => new SqliteConfigurationRepository(directory, executable),
        ).toThrow("configuration_owner_exists");
        const [committed, conflict] = await Promise.all([
          owner.request(rename),
          owner.request({
            ...rename,
            operationId: "other",
            name: "Conflicting",
          }),
        ]);
        expect(committed.kind).toBe("committed");
        expect(conflict).toEqual({
          version: 1,
          kind: "conflict",
          currentRevision: "2",
        });
        if (committed.kind !== "committed")
          throw new Error("test_commit_missing");
        await close(owner);
        owner = new ConfigurationOwner(executable, directory, launcher);
        await owner.ready;
        expect(await owner.request(rename)).toEqual({
          ...committed,
          replayed: true,
        });
        const catalog = await owner.request(list);
        expect(catalog.kind).toBe("catalog");
        if (catalog.kind === "catalog") {
          expect(catalog.revision).toBe("2");
          expect(catalog.profiles[0]?.name).toBe(rename.name);
        }
      } finally {
        await close(owner);
      }
      const reopened = new SqliteConfigurationRepository(directory, executable);
      try {
        expect(reopened.current()?.revision).toBe("2");
      } finally {
        reopened.close();
      }
    }),
  10000,
);

test(
  "configuration owner death rejects pending work and releases its database lease",
  async () =>
    fixture(async (directory) => {
      const owner = new ConfigurationOwner(executable, directory, launcher);
      await owner.ready;
      owner.child.kill("SIGKILL");
      try {
        await expect(owner.request(list)).rejects.toThrow(
          "configuration_owner_unavailable",
        );
      } finally {
        await close(owner);
      }
      const reopened = new SqliteConfigurationRepository(directory, executable);
      try {
        expect(reopened.current()).toBeUndefined();
      } finally {
        reopened.close();
      }
    }),
  10000,
);

test(
  "private configuration protocol refuses raw commits and malformed framing without reflecting source",
  async () =>
    fixture(async (directory) => {
      for (const malformed of [
        JSON.stringify({ version: 9, requestId: "bad", body: list }) + "\n",
        "x".repeat(65537),
      ]) {
        const child = Bun.spawn(
          [
            ...launcher,
            "__configuration",
            "run",
            "--runtime-dir",
            directory,
            "--receiver",
            executable,
          ],
          { stdin: "pipe", stdout: "pipe", stderr: "pipe" },
        );
        child.stdin.write(
          JSON.stringify({
            version: 1,
            requestId: "raw",
            body: {
              command: "commit",
              source: "private-source-must-not-appear",
              payloadHash: "a".repeat(64),
            },
          }) +
            "\n" +
            malformed,
        );
        child.stdin.end();
        const [out, err, code] = await Promise.all([
          new Response(child.stdout).text(),
          new Response(child.stderr).text(),
          child.exited,
        ]);
        expect(code).toBe(1);
        expect(err).toBe("");
        expect(out.includes("private-source")).toBe(false);
        const lines = out
          .trim()
          .split("\n")
          .map((line) => JSON.parse(line));
        expect(lines[0]?.ready).toBe("configuration");
        expect(
          lines.some(
            (line) =>
              line.requestId === "raw" &&
              line.error === "invalid_configuration_request",
          ),
        ).toBe(true);
        expect(lines.at(-1)?.ok).toBe(false);
      }
    }),
  10000,
);

test.skipIf(process.platform === "win32")(
  "a suspended configuration child cannot block native owner renewal or input publication",
  async () =>
    fixture(async (directory) => {
      const seed = new SqliteConfigurationRepository(directory, executable);
      seed.close();
      const owner = new ConfigurationOwner(executable, directory, launcher);
      const native = new NativeReceiver(
        executable,
        directory,
        join(directory, "isolation-recording.jsonl"),
      );
      const controller = new RuntimeController(native, randomUUID);
      let stopped = false;
      try {
        await Promise.all([owner.ready, native.ready]);
        await controller.execute({
          command: "activate",
          expectedRevision: "0",
          profileId: "isolation",
        });
        expect(owner.child.kill("SIGSTOP")).toBe(true);
        stopped = true;
        let settled = false;
        const pending = owner.request(list).finally(() => {
          settled = true;
        });
        // Longer than the unchanged 750 ms owner lease, shorter than the private RPC deadline.
        const started = performance.now();
        let sequence = 0;
        do {
          await controller.renew();
          const snapshot = await controller.execute({
            command: "sample",
            expectedGeneration: "1",
            sequence: String(sequence++),
            state: { ...neutralGamepadState(), buttons: ["south"] },
            allowRecordedInput: true,
          });
          expect(snapshot.active).toBe(true);
          expect(snapshot.inputEnabled).toBe(false);
          await Bun.sleep(100);
        } while (performance.now() - started < 1000);
        expect(settled).toBe(false);
        expect(owner.child.kill("SIGCONT")).toBe(true);
        stopped = false;
        expect((await pending).kind).toBe("catalog");
        expect((await controller.execute({ command: "status" })).active).toBe(
          true,
        );
      } finally {
        if (stopped) owner.child.kill("SIGCONT");
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
  10000,
);

test(
  "configuration output backpressure preserves every queued reply through EOF",
  async () =>
    fixture(async (directory) => {
      const seed = new SqliteConfigurationRepository(directory, executable);
      let source = catalogFixtureSource(18);
      for (let i = 0; i < 16; i++)
        source = source.set(
          `/profiles/${i}/name`,
          JSON.stringify("🦊".repeat(256)),
        );
      seed.commit({
        operationId: "seed",
        payloadHash: "b".repeat(64),
        expectedRevision: "0",
        source,
        affectedEntities: [],
      });
      seed.close();
      const child = Bun.spawn(
        [
          ...launcher,
          "__configuration",
          "run",
          "--runtime-dir",
          directory,
          "--receiver",
          executable,
        ],
        { stdin: "pipe", stdout: "pipe", stderr: "pipe" },
      );
      const reader = child.stdout.getReader(),
        first = await reader.read();
      expect(first.done).toBe(false);
      const chunks = [Buffer.from(first.value!)];
      for (let i = 0; i < 16; i++)
        child.stdin.write(
          JSON.stringify({ version: 1, requestId: `queued-${i}`, body: list }) +
            "\n",
        );
      child.stdin.end();
      // Let the child fill its pipe before this peer starts consuming catalog replies.
      await Bun.sleep(100);
      const remainder = (async () => {
        for (;;) {
          const next = await reader.read();
          if (next.done) break;
          chunks.push(Buffer.from(next.value));
        }
      })();
      const [, err, code] = await Promise.all([
        remainder,
        new Response(child.stderr).text(),
        child.exited,
      ]);
      expect(code).toBe(0);
      expect(err).toBe("");
      const frames = Buffer.concat(chunks)
        .toString("utf8")
        .trim()
        .split("\n")
        .map((line) => JSON.parse(line));
      expect(frames.length).toBe(17);
      for (let i = 0; i < 16; i++) {
        expect(frames[i + 1]?.requestId).toBe(`queued-${i}`);
        expect(frames[i + 1]?.result.profiles.length).toBe(16);
      }
    }),
  10000,
);

test(
  "an invalid typed configuration result disconnects the owner instead of keeping a poisoned pipe",
  async () =>
    fixture(async (directory) => {
      const owner = new ConfigurationOwner(executable, directory, [
        process.execPath,
        resolve(import.meta.dir, "fixtures/invalid-configuration-owner.ts"),
      ]);
      // [DEBUG-config-peer] The synthetic peer emits only these fixed phases.
      const phases: string[] = [];
      let stdoutBytes = 0,
        stdoutLines = 0;
      owner.child.stdout.on("data", (chunk: Buffer) => {
        stdoutBytes = Math.min(1048576, stdoutBytes + chunk.byteLength);
        for (const byte of chunk)
          if (byte === 10) stdoutLines = Math.min(1024, stdoutLines + 1);
      });
      owner.child.stderr.on("data", (chunk: Buffer) => {
        for (const phase of chunk
          .toString("utf8")
          .match(/test_peer_(?:listening|input|reply|flushed|end)/g) ?? [])
          if (phases.length < 16) phases.push(phase);
      });
      const exited = once(owner.child, "exit");
      let deadline: ReturnType<typeof setTimeout> | undefined;
      try {
        await owner.ready;
        await expect(owner.request(list)).rejects.toThrow(
          "configuration_response_invalid",
        );
        await Promise.race([
          exited,
          new Promise((_, reject) => {
            deadline = setTimeout(
              () => reject(new Error("test_invalid_owner_did_not_exit")),
              1000,
            );
          }),
        ]);
        expect(owner.child.exitCode).toBe(0);
      } catch (error) {
        console.log(
          "[DEBUG-config-peer] " +
            JSON.stringify({
              phases,
              stdoutBytes,
              stdoutLines,
              pipe: owner.diagnostics,
            }),
        );
        throw error;
      } finally {
        if (deadline) clearTimeout(deadline);
        await close(owner);
      }
    }),
  10000,
);
