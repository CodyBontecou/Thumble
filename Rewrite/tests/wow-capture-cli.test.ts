import { expect, test } from "bun:test";
import {
  chmodSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
const root = resolve(import.meta.dir, ".."),
  cli = join(root, "apps/cli/src/main.ts");
async function command(runtime: string, ...args: string[]) {
  const p = Bun.spawn(
    [process.execPath, cli, ...args, "--runtime-dir", runtime, "--json"],
    { cwd: root, stdout: "pipe", stderr: "pipe" },
  );
  const [out, err, code] = await Promise.all([
    new Response(p.stdout).text(),
    new Response(p.stderr).text(),
    p.exited,
  ]);
  expect(err).toBe("");
  const value = JSON.parse(out);
  return { code, ...value };
}
test.skipIf(process.platform !== "darwin")(
  "actual CLI service keeps capture disabled by default; explicit fake helper is isolated and never receives paths/windows",
  async () => {
    const parent = realpathSync(
        mkdtempSync(join(tmpdir(), "thumble-capture-cli-")),
      ),
      runtime = join(parent, "runtime"),
      helper = join(parent, "helper");
    writeFileSync(
      helper,
      `#!${process.execPath}\nlet b=Buffer.alloc(0);process.stdin.on('data',c=>{b=Buffer.concat([b,c]);while(b.length>=4&&b.length>=4+b.readUInt32BE()){const n=b.readUInt32BE(),r=JSON.parse(b.subarray(4,4+n));b=b.subarray(4+n);const v=Buffer.from(JSON.stringify({...r,command:'wow-capture-result',kind:'status',status:'game-not-visible'})),h=Buffer.alloc(4);h.writeUInt32BE(v.length);process.stdout.write(Buffer.concat([h,v]));}});`,
    );
    chmodSync(helper, 0o700);
    try {
      expect((await command(runtime, "service", "start")).ok).toBe(true);
      expect((await command(runtime, "wow", "capture-status")).result).toEqual({
        kind: "wow-capture",
        enabled: false,
        state: "disabled",
        permission: "not-inspected",
        source: null,
        generation: null,
        receipt: null,
      });
      expect(
        (
          await command(
            runtime,
            "wow",
            "capture-start",
            "--source",
            "world-of-warcraft",
          )
        ).error,
      ).toBe("wow_capture_not_enabled");
      await command(runtime, "service", "stop");
      // Endpoint removal is the existing service restart barrier.
      for (let i = 0; i < 60; i++) {
        const v = await command(runtime, "service", "status");
        if (!v.ok) break;
        await Bun.sleep(25);
      }
      expect(
        (await command(runtime, "service", "start", "--capture-helper", helper))
          .ok,
      ).toBe(true);
      expect(
        (await command(runtime, "wow", "capture-status")).result.state,
      ).toBe("stopped");
      expect(
        (
          await command(
            runtime,
            "wow",
            "capture-start",
            "--source",
            "world-of-warcraft",
          )
        ).ok,
      ).toBe(true);
      let ready;
      for (let i = 0; i < 30; i++) {
        ready = await command(runtime, "wow", "capture-status");
        if (ready.result.receipt) break;
        await Bun.sleep(20);
      }
      expect(ready.result.receipt.status).toBe("game-not-visible");
      expect(ready.result.permission).toBe("not-inspected");
      expect(ready.result.source).toBe(1);
      expect(
        (await command(runtime, "receiver", "status")).result.receiver.snapshot
          .backend,
      ).toBe("recording");
      expect(
        (await command(runtime, "wow", "capture-stop")).result.receipt,
      ).toBeNull();
    } finally {
      await command(runtime, "service", "stop");
      await Bun.sleep(100);
      rmSync(parent, { recursive: true, force: true });
    }
  },
  20000,
);
