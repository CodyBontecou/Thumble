import { expect, test } from "bun:test";
import { mkdtempSync, realpathSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createServer } from "node:net";
import { readEndpoint, request, requestPairing } from "@thumble/client/local";
import { decodeAuthorizedListener } from "@thumble/contracts/pairing";
const cli = resolve(import.meta.dir, "../apps/cli/src/main.ts"),
  receiver = resolve(
    import.meta.dir,
    "../native/receiver/target/debug/thumble-rewrite-receiver" +
      (process.platform === "win32" ? ".exe" : ""),
  );
async function command(runtime: string, ...args: string[]) {
  const child = Bun.spawn(
    [
      process.execPath,
      cli,
      ...args,
      ...(args[0] === "identity" ? [] : ["--runtime-dir", runtime]),
      "--receiver",
      receiver,
      "--json",
    ],
    { stdout: "pipe", stderr: "pipe" },
  );
  const timer = setTimeout(() => child.kill(), 9000);
  try {
    const [stdout, stderr, code] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited,
    ]);
    expect(stderr).toBe("");
    return { code, value: JSON.parse(stdout) };
  } finally {
    clearTimeout(timer);
  }
}
async function boundPort() {
  const server = createServer();
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (!address || typeof address === "string")
    throw Error("test_listener_failed");
  return {
    server,
    port: address.port,
    async close() {
      await new Promise<void>((resolve, reject) =>
        server.close((error) => (error ? reject(error) : resolve())),
      );
    },
  };
}
async function fixture(
  run: (runtime: string, identity: string) => Promise<void>,
) {
  const parent = realpathSync(
      mkdtempSync(join(tmpdir(), "thumble-auth-start-")),
    ),
    runtime = join(parent, "runtime"),
    identity = join(parent, "identity");
  try {
    await run(runtime, identity);
  } finally {
    try {
      await request(readEndpoint(runtime, receiver), { command: "stop" });
    } catch {}
    await gone(runtime);
    rmSync(parent, { recursive: true, force: true });
  }
}
async function gone(runtime: string) {
  const until = Date.now() + 4000;
  while (existsSync(join(runtime, "endpoint.json")) && Date.now() < until)
    await Bun.sleep(20);
  expect(existsSync(join(runtime, "endpoint.json"))).toBe(false);
}

test("auth-only listener options require explicit nonzero IP port and concrete advertised host", () => {
  for (const bindAddress of [
    "127.0.0.1:0",
    "localhost:1234",
    "127.0.0.1",
    "127.0.0.1:65536",
    "127.00.0.1:1234",
    "999.0.0.1:1234",
  ]) {
    let error: unknown;
    try {
      decodeAuthorizedListener({ bindAddress, advertiseHost: "127.0.0.1" });
    } catch (e) {
      error = e;
    }
    expect(error).toBeInstanceOf(Error);
  }
  for (const advertiseHost of [
    "0.0.0.0",
    "::",
    "0:0:0:0:0:0:0:0",
    "bad/host",
  ]) {
    let error: unknown;
    try {
      decodeAuthorizedListener({
        bindAddress: "127.0.0.1:1234",
        advertiseHost,
      });
    } catch (e) {
      error = e;
    }
    expect(error).toBeInstanceOf(Error);
  }
  expect(
    decodeAuthorizedListener({
      bindAddress: "[::1]:1234",
      advertiseHost: "::1",
    }).bindAddress,
  ).toBe("[::1]:1234");
});
test(
  "default service has no network; explicit auth-only startup restarts same port/pin with closed pairing and neutral recording",
  async () =>
    fixture(async (runtime, identity) => {
      const initial = await command(runtime, "service", "start");
      expect(initial.code).toBe(0);
      expect(
        (
          await requestPairing(readEndpoint(runtime, receiver), {
            command: "pairing-status",
          })
        ).transport?.listening,
      ).toBe(false);
      await command(runtime, "service", "stop");
      await gone(runtime);
      expect(
        (
          await command(
            runtime,
            "identity",
            "initialize",
            "--identity-dir",
            identity,
          )
        ).code,
      ).toBe(0);
      const reserved = await boundPort(),
        address = `127.0.0.1:${reserved.port}`;
      await reserved.close();
      const launch = [
        "--identity-dir",
        identity,
        "--listen-address",
        address,
        "--advertise-host",
        "127.0.0.1",
      ];
      expect((await command(runtime, "service", "start", ...launch)).code).toBe(
        0,
      );
      const first = await requestPairing(readEndpoint(runtime, receiver), {
        command: "pairing-status",
      });
      expect(first.pairing.state).toBe("closed");
      expect(first.offer).toBe(null);
      expect(first.transport?.port).toBe(reserved.port);
      expect(first.transport?.persistentIdentity).toBe(true);
      expect(
        (await command(runtime, "service", "start", ...launch)).value.error,
      ).toBe("service_launch_options_restart_required");
      expect(
        (await command(runtime, "pairing", "open", "--reveal-secret")).value
          .result.pairing.state,
      ).toBe("open");
      const authorized = await command(
        runtime,
        "pairing",
        "listen-authorized",
        "--bind-address",
        address,
        "--advertise-host",
        "127.0.0.1",
      );
      expect(authorized.code).toBe(0);
      expect(authorized.value.result.offer).toBe(null);
      expect(authorized.value.result.pairing.state).toBe("closed");
      await command(runtime, "service", "stop");
      await gone(runtime);
      expect((await command(runtime, "service", "start", ...launch)).code).toBe(
        0,
      );
      const second = await requestPairing(readEndpoint(runtime, receiver), {
        command: "pairing-status",
      });
      expect(second.transport?.port).toBe(first.transport?.port);
      expect(second.transport?.certificatePin).toBe(
        first.transport?.certificatePin,
      );
      expect(second.authorityInstanceId).not.toBe(first.authorityInstanceId);
      expect(second.offer).toBe(null);
      expect(second.pairing.state).toBe("closed");
      const status = await request(readEndpoint(runtime, receiver), {
        command: "status",
      });
      expect(status.receiver.snapshot.active).toBe(false);
      expect(status.receiver.snapshot.inputEnabled).toBe(false);
    }),
  20000,
);

test(
  "startup bind conflict rolls back child ownership and never publishes ready endpoint",
  async () =>
    fixture(async (runtime, identity) => {
      expect(
        (
          await command(
            runtime,
            "identity",
            "initialize",
            "--identity-dir",
            identity,
          )
        ).code,
      ).toBe(0);
      const occupied = await boundPort();
      const launch = [
        "--identity-dir",
        identity,
        "--listen-address",
        `127.0.0.1:${occupied.port}`,
        "--advertise-host",
        "127.0.0.1",
      ];
      try {
        const failed = await command(runtime, "service", "run", ...launch);
        expect(failed.code).toBe(1);
        expect(failed.value.error).toBe("pairing_bind_failed");
        expect(existsSync(join(runtime, "endpoint.json"))).toBe(false);
      } finally {
        await occupied.close();
      }
      // One subsequent startup proves receiver/configuration/trust leases were released, without retrying the failed bind.
      expect((await command(runtime, "service", "start", ...launch)).code).toBe(
        0,
      );
      expect(
        (
          await requestPairing(readEndpoint(runtime, receiver), {
            command: "pairing-status",
          })
        ).pairing.state,
      ).toBe("closed");
    }),
  15000,
);

test(
  "invalid identity and wildcard launch reject without a ready endpoint or hidden children",
  async () =>
    fixture(async (runtime, identity) => {
      const missing = await command(
        runtime,
        "service",
        "run",
        "--listen-address",
        "127.0.0.1:1234",
        "--advertise-host",
        "127.0.0.1",
      );
      expect(missing.value.error).toBe(
        "auth_listener_persistent_identity_required",
      );
      expect(existsSync(runtime)).toBe(false);
      const wildcard = await command(
        runtime,
        "service",
        "run",
        "--identity-dir",
        identity,
        "--listen-address",
        "127.0.0.1:1234",
        "--advertise-host",
        "0.0.0.0",
      );
      expect(wildcard.code).toBe(1);
      expect(existsSync(runtime)).toBe(false);
      const absentIdentity = await command(
        runtime,
        "service",
        "run",
        "--identity-dir",
        identity,
        "--listen-address",
        "127.0.0.1:1234",
        "--advertise-host",
        "127.0.0.1",
      );
      expect(absentIdentity.code).toBe(1);
      expect(absentIdentity.value.error).toBe("pairing_host_unavailable");
      expect(existsSync(join(runtime, "endpoint.json"))).toBe(false);
      // A normal one-shot startup after failed ownership proves all child leases were released.
      expect((await command(runtime, "service", "start")).code).toBe(0);
      expect(
        (
          await requestPairing(readEndpoint(runtime, receiver), {
            command: "pairing-status",
          })
        ).transport?.listening,
      ).toBe(false);
    }),
  15000,
);
