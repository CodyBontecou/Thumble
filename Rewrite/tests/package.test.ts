import { expect, test } from "bun:test";
import {
  existsSync,
  copyFileSync,
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
      expect(code).toBe(0);
      return parseStrictJson(out);
    };
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
      expect(started.result.receiver.snapshot.backend).toBe("recording");
      expect(started.result.receiver.snapshot.inputEnabled).toBe(false);
      const status = await invoke("status");
      expect(status.result.service.instanceId).toBe(
        started.result.service.instanceId,
      );
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
      const stopped = await invoke("stop");
      expect(stopped.result.receiver.snapshot.active).toBe(false);
      const deadline = Date.now() + 3000;
      while (
        existsSync(join(runtime, "endpoint.json")) &&
        Date.now() < deadline
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
  20000,
);
