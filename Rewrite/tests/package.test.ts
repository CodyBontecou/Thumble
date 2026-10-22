import { LosslessJson } from "@thumble/contracts/json";
import { OwnedAuthorityDocument } from "@thumble/domain/owned-authority";
import { encodeResourceBase64 } from "@thumble/domain/owned-resources";
import { createHash } from "node:crypto";
import { FileAssetStore } from "@thumble/storage/asset-files";
import { SqliteConfigurationRepository } from "@thumble/storage";
import { a, b } from "./helpers/configuration-fixture.ts";
import { expect, test } from "bun:test";
import {
  existsSync,
  readFileSync,
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  realpathSync,
  rmSync,
} from "node:fs";
import { resolve, join } from "node:path";
import { tmpdir } from "node:os";
import { parseStrictJson } from "@thumble/contracts/receiver";
const root = resolve(import.meta.dir, ".."),
  extension = process.platform === "win32" ? ".exe" : "";
const packageTest =
  process.env.THUMBLE_REWRITE_PACKAGE_TEST === "1" ? test : test.skip;
packageTest(
  "compiled CLI starts and stops its sibling native receiver without a checkout or Bun on PATH",
  async () => {
    const directory = realpathSync(
        mkdtempSync(join(tmpdir(), "thumble-package-")),
      ),
      runtime = join(directory, "runtime");
    for (const name of ["thumble-rewrite", "thumble-rewrite-receiver"])
      copyFileSync(
        resolve(root, `dist/${name}${extension}`),
        join(directory, `${name}${extension}`),
      );
    const invoke = async (
      action: string,
      family = "service",
      ...options: string[]
    ): Promise<any> => {
      const startedAt = performance.now();
      const child = Bun.spawn(
        [
          join(directory, `thumble-rewrite${extension}`),
          family,
          action,
          ...options,
          ...(family === "identity"
            ? ["--identity-dir", join(directory, "identity")]
            : ["--runtime-dir", runtime]),
          "--json",
        ],
        {
          cwd: directory,
          env: {
            ...process.env,
            PATH:
              process.platform === "win32"
                ? (process.env.SystemRoot ?? "C:\\Windows") + "\\System32"
                : "/usr/bin:/bin",
          },
          stdout: "pipe",
          stderr: "pipe",
        },
      );
      const [out, err, code] = await Promise.all([
        new Response(child.stdout).text(),
        new Response(child.stderr).text(),
        child.exited,
      ]);
      expect(err).toBe("");
      if (code !== 0) {
        // Successful replies can contain enrollment secrets. Report only the
        // bounded public error code, never raw CLI output or caller options.
        let reason = "invalid_error_response";
        try {
          const reply = parseStrictJson(out);
          if (
            typeof reply === "object" &&
            reply !== null &&
            "ok" in reply &&
            "error" in reply &&
            reply.ok === false &&
            typeof reply.error === "string" &&
            /^[a-z_]{1,80}$/.test(reply.error)
          )
            reason = reply.error;
        } catch {}
        throw new Error(
          `package ${family} ${action}: ${reason}; exit=${code}; elapsedMs=${Math.round(performance.now() - startedAt)}`,
        );
      }
      return parseStrictJson(out);
    };
    const inspection = join(directory, "inspection");
    mkdirSync(inspection);
    const bareCli = join(inspection, `thumble-rewrite${extension}`),
      ownedFile = join(inspection, "owned.json");
    copyFileSync(join(directory, `thumble-rewrite${extension}`), bareCli);
    copyFileSync(
      resolve(root, "packages/fixtures/owned-configuration-v1/document.json"),
      ownedFile,
    );
    const fileProbe = Bun.spawn(
      [
        "node",
        resolve(root, "tooling/test-configuration-file-node.mjs"),
        process.execPath,
        bareCli,
        ownedFile,
        inspection,
        process.platform === "win32"
          ? (process.env.SystemRoot ?? "C:\\Windows") + "\\System32"
          : "/usr/bin:/bin",
      ],
      { stdout: "pipe", stderr: "pipe" },
    );
    const [fileOut, fileErr, fileCode] = await Promise.all([
      new Response(fileProbe.stdout).text(),
      new Response(fileProbe.stderr).text(),
      fileProbe.exited,
    ]);
    expect(fileErr).toBe("");
    expect(fileCode).toBe(0);
    expect(JSON.parse(fileOut)).toEqual({
      ok: true,
      scenarios: 2,
      server: "standalone",
      serviceRequired: false,
    });
    const importProbe = Bun.spawn(
      [
        "node",
        resolve(root, "tooling/test-configuration-import-node.mjs"),
        process.execPath,
        join(directory, `thumble-rewrite${extension}`),
        join(directory, `thumble-rewrite-receiver${extension}`),
        join(directory, "import-runtime"),
        ownedFile,
        process.platform === "win32"
          ? (process.env.SystemRoot ?? "C:\\Windows") + "\\System32"
          : "/usr/bin:/bin",
      ],
      { stdout: "pipe", stderr: "pipe" },
    );
    const [importOut, importErr, importCode] = await Promise.all([
      new Response(importProbe.stdout).text(),
      new Response(importProbe.stderr).text(),
      importProbe.exited,
    ]);
    expect(importErr).toBe("");
    expect(importCode).toBe(0);
    expect(JSON.parse(importOut)).toEqual({
      ok: true,
      scenarios: 4,
      imports: 2,
      server: "standalone",
    });
    const configuration = new SqliteConfigurationRepository(
      runtime,
      join(directory, `thumble-rewrite-receiver${extension}`),
    );
    const assetBytes = new TextEncoder().encode("standalone synthetic asset");
    const assetSHA = createHash("sha256").update(assetBytes).digest("hex");
    const ownedSource = LosslessJson.parse(
      readFileSync(ownedFile, "utf8")
        .replace(/EA000000-0000-0000-0000-000000000001/gi, b)
        .replace(/0F38B980-9D36-56B6-8425-826EA40B149D/gi, a),
    ).set(
      "/profiles/0/appearanceResources/" + assetSHA,
      JSON.stringify(encodeResourceBase64(assetBytes)),
    );
    const prepared = OwnedAuthorityDocument.prepare(ownedSource, (bytes) =>
      createHash("sha256").update(bytes).digest("hex"),
    );
    try {
      configuration.commit({
        operationId: "fixture-seed",
        payloadHash: "f".repeat(64),
        expectedRevision: "0",
        source: prepared.document.source,
        assets: prepared.assets(),
        affectedEntities: [a, b],
      });
    } finally {
      configuration.close();
    }
    expect(
      new FileAssetStore(
        runtime,
        join(directory, `thumble-rewrite-receiver${extension}`),
      ).read(assetSHA),
    ).toEqual(assetBytes);
    try {
      const identity = await invoke("initialize", "identity");
      expect(identity.result.certificatePin).toMatch(/^[0-9a-f]{64}$/);
      expect(identity.result.inputEnabled).toBe(false);
      expect((await invoke("show", "identity")).result).toEqual(
        identity.result,
      );
      const started = await invoke(
        "start",
        "service",
        "--identity-dir",
        join(directory, "identity"),
      );
      expect(existsSync(join(runtime, "configuration-v1.sqlite3"))).toBe(true);
      expect(started.result.receiver.snapshot.backend).toBe("recording");
      expect(started.result.receiver.snapshot.inputEnabled).toBe(false);
      const status = await invoke("status");
      expect(status.result.service.instanceId).toBe(
        started.result.service.instanceId,
      );
      const configurationProbe = Bun.spawn(
        [
          "node",
          resolve(root, "tooling/test-configuration-mcp-node.mjs"),
          process.execPath,
          join(directory, `thumble-rewrite${extension}`),
          join(directory, `thumble-rewrite-receiver${extension}`),
          runtime,
          process.platform === "win32"
            ? (process.env.SystemRoot ?? "C:\\Windows") + "\\System32"
            : "/usr/bin:/bin",
        ],
        { stdout: "pipe", stderr: "pipe" },
      );
      const [configurationOut, configurationErr, configurationCode] =
        await Promise.all([
          new Response(configurationProbe.stdout).text(),
          new Response(configurationProbe.stderr).text(),
          configurationProbe.exited,
        ]);
      expect(configurationErr).toBe("");
      expect(configurationCode).toBe(0);
      expect(JSON.parse(configurationOut)).toEqual({
        ok: true,
        scenarios: 4,
        server: "standalone",
      });
      const pairing = await invoke("open", "pairing", "--reveal-secret");
      expect(pairing.result.offer.secret).toMatch(/^[0-9a-f]{64}$/);
      const pairingStatus = await invoke("status", "pairing");
      expect(pairingStatus.result.pairing.state).toBe("open");
      expect(pairingStatus.result.offer).toBe(null);
      expect(JSON.stringify(pairingStatus)).not.toContain(
        pairing.result.offer.secret,
      );
      expect((await invoke("cancel", "pairing")).result.pairing.state).toBe(
        "closed",
      );
      const listening = await invoke(
        "listen",
        "pairing",
        "--bind-address",
        "127.0.0.1:0",
        "--advertise-host",
        "127.0.0.1",
        "--reveal-secret",
      );
      expect(listening.result.transport.listening).toBe(true);
      const peer = Bun.spawn(
        ["node", resolve(root, "tooling/check-pairing-listener.mjs")],
        { stdin: "pipe", stdout: "pipe", stderr: "pipe" },
      );
      try {
        peer.stdin.write(
          JSON.stringify({
            invitation: listening.result.offer,
            transport: listening.result.transport,
          }) + "\n",
        );
        peer.stdin.end();
        const [text, error, code] = await Promise.all([
          new Response(peer.stdout).text(),
          new Response(peer.stderr).text(),
          peer.exited,
        ]);
        expect(code).toBe(0);
        expect(error).toBe("");
        expect(JSON.parse(text).completed).toBe(true);
        expect(JSON.parse(text).authenticated).toBe(true);
        expect(JSON.parse(text).inputEnabled).toBe(false);
      } finally {
        if (peer.exitCode === null) peer.kill();
      }
      expect((await invoke("status", "pairing")).result.pairing.state).toBe(
        "closed",
      );
      const phones = (await invoke("list", "pairing")).result.phones;
      expect(phones).toHaveLength(1);
      expect(phones[0].phoneId).toBe("oracle-phone");
      expect(phones[0].active).toBe(true);
      const revoked = await invoke(
        "revoke",
        "pairing",
        "--phone-id",
        "oracle-phone",
      );
      expect(revoked.result.phones[0].active).toBe(false);
      expect(revoked.result.offer).toBe(null);
      expect(revoked.result.transport.listening).toBe(true);
      expect(
        (await invoke("stop-listening", "pairing")).result.transport.listening,
      ).toBe(false);
      const mcp = Bun.spawn(
        [
          "node",
          resolve(root, "tooling/test-mcp-node.mjs"),
          process.execPath,
          join(directory, `thumble-rewrite${extension}`),
          join(directory, `thumble-rewrite-receiver${extension}`),
          process.platform === "win32"
            ? (process.env.SystemRoot ?? "C:\\Windows") + "\\System32"
            : "/usr/bin:/bin",
        ],
        { cwd: directory, stdout: "pipe", stderr: "pipe" },
      );
      const [mcpOutput, mcpError, mcpCode] = await Promise.all([
        new Response(mcp.stdout).text(),
        new Response(mcp.stderr).text(),
        mcp.exited,
      ]);
      expect(mcpError).toBe("");
      expect(mcpCode).toBe(0);
      expect(JSON.parse(mcpOutput)).toEqual({
        ok: true,
        runtime: expect.stringMatching(/^v[0-9]+\.[0-9]+\.[0-9]+$/),
        eras: ["modern", "legacy"],
        scenarios: 4,
        server: "standalone",
        inputEnabled: false,
      });
      expect((await invoke("status")).ok).toBe(true);
      const stopped = await invoke("stop");
      expect(stopped.result.receiver.snapshot.active).toBe(false);
      const deadline = Date.now() + 3000;
      while (
        existsSync(join(runtime, "endpoint.json")) &&
        Date.now() < deadline
      )
        await Bun.sleep(20);
      expect(existsSync(join(runtime, "endpoint.json"))).toBe(false);
      const reopened = new SqliteConfigurationRepository(
        runtime,
        join(directory, `thumble-rewrite-receiver${extension}`),
      );
      try {
        const stored = OwnedAuthorityDocument.read(reopened.current()!.source);
        expect(stored.resources).toEqual(prepared.document.resources);
        const files = new FileAssetStore(
          runtime,
          join(directory, `thumble-rewrite-receiver${extension}`),
        );
        const restored = stored.materialize(
          (key) => files.read(key),
          (bytes) => createHash("sha256").update(bytes).digest("hex"),
        );
        expect(
          restored.catalog.profiles.find((profile) => profile.id === a)?.name,
        ).toBe("SDK legacy 🦊");
        expect(restored.source.get("/profiles/0/customization")?.text()).toBe(
          ownedSource.get("/profiles/0/customization")?.text(),
        );
      } finally {
        reopened.close();
      }
      await invoke("start");
      expect((await invoke("list", "configuration")).result.revision).toBe("3");
      const replay = await invoke(
        "rename-profile",
        "configuration",
        "--operation-id",
        "sdk-modern",
        "--expected-revision",
        "1",
        "--profile-id",
        a,
        "--name",
        "SDK modern 🦊",
      );
      expect(replay.result.replayed).toBe(true);
      expect(replay.result.receipt.resultingRevision).toBe("2");
      await invoke("stop");
      const restartDeadline = Date.now() + 3000;
      while (
        existsSync(join(runtime, "endpoint.json")) &&
        Date.now() < restartDeadline
      )
        await Bun.sleep(20);
      expect(existsSync(join(runtime, "endpoint.json"))).toBe(false);
    } finally {
      if (existsSync(join(runtime, "endpoint.json"))) {
        try {
          await invoke("stop");
        } catch {}
      }
      for (let i = 0; i < 100; i++) {
        try {
          rmSync(directory, { recursive: true, force: true });
          break;
        } catch {
          await Bun.sleep(20);
        }
      }
    }
  },
  30000,
);
