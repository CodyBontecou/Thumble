import { expect, test } from "bun:test";
import {
  copyFileSync,
  mkdtempSync,
  existsSync,
  readFileSync,
  writeFileSync,
  rmSync,
  realpathSync,
} from "node:fs";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
const packageTest =
  process.env.THUMBLE_REWRITE_CAPTURE_PACKAGE_TEST === "1" ? test : test.skip;
packageTest(
  "optional optical package is portable without checkout and uses an explicitly selected fake helper only",
  async () => {
    const root = resolve(import.meta.dir, ".."),
      extension = process.platform === "win32" ? ".exe" : "",
      directory = realpathSync(
        mkdtempSync(join(tmpdir(), "thumble-capture-standalone-")),
      ),
      runtime = join(directory, "runtime");
    const manifest = JSON.parse(
      readFileSync(join(root, "dist/WOW-CAPTURE-MANIFEST.json"), "utf8"),
    );
    for (const name of [
      "thumble-rewrite" + extension,
      "thumble-rewrite-receiver" + extension,
      manifest.helper.name,
      manifest.notices.name,
      "WOW-CAPTURE-MANIFEST.json",
    ]) {
      copyFileSync(join(root, "dist", name), join(directory, name));
    }
    expect(
      createHash("sha256")
        .update(readFileSync(join(directory, manifest.helper.name)))
        .digest("hex"),
    ).toBe(manifest.helper.sha256);
    expect(manifest.osCaptureExecuted).toBe(false);
    const fakeSource = join(directory, "synthetic.ts"),
      fake = join(directory, "synthetic-capture" + extension);
    // Owned synthetic executable; the packaged real helper is verified, NEVER run.
    writeFileSync(
      fakeSource,
      `let b=Buffer.alloc(0);process.stdin.on('data',c=>{b=Buffer.concat([b,c]);while(b.length>=4&&b.length>=4+b.readUInt32BE()){const n=b.readUInt32BE(),r=JSON.parse(b.subarray(4,4+n));b=b.subarray(4+n);const v=Buffer.from(JSON.stringify({...r,command:'wow-capture-result',kind:'status',status:'game-not-visible'})),h=Buffer.alloc(4);h.writeUInt32BE(v.length);process.stdout.write(Buffer.concat([h,v]));}});`,
    );
    const compile = Bun.spawn(
      [process.execPath, "build", "--compile", fakeSource, "--outfile", fake],
      { stdout: "ignore", stderr: "pipe" },
    );
    const compileError = await new Response(compile.stderr).text();
    expect(await compile.exited).toBe(0);
    expect(compileError).toBe("");
    rmSync(fakeSource);
    async function invoke(...args: string[]) {
      const child = Bun.spawn(
        [
          join(directory, "thumble-rewrite" + extension),
          ...args,
          "--runtime-dir",
          runtime,
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
      const timer = setTimeout(() => child.kill("SIGKILL"), 7000);
      try {
        const [out, err, code] = await Promise.all([
          new Response(child.stdout).text(),
          new Response(child.stderr).text(),
          child.exited,
        ]);
        expect(err).toBe("");
        expect(code).toBe(0);
        return JSON.parse(out);
      } finally {
        clearTimeout(timer);
      }
    }
    try {
      expect((await invoke("service", "start")).ok).toBe(true);
      expect((await invoke("wow", "capture-status")).result.enabled).toBe(
        false,
      );
      await invoke("service", "stop");
      // Endpoint disappearance is the existing confirmed native-owner restart
      // barrier; the stop response itself precedes asynchronous owner cleanup.
      for (
        let index = 0;
        index < 300 && existsSync(join(runtime, "endpoint.json"));
        index++
      )
        await Bun.sleep(10);
      expect(existsSync(join(runtime, "endpoint.json"))).toBe(false);
      expect(
        (await invoke("service", "start", "--capture-helper", fake)).ok,
      ).toBe(true);
      await invoke("wow", "capture-start", "--source", "world-of-warcraft");
      let status;
      for (let index = 0; index < 30; index++) {
        status = (await invoke("wow", "capture-status")).result;
        if (status.receipt) break;
        await Bun.sleep(20);
      }
      expect(status.receipt.kind).toBe("status");
      expect(status.receipt.status).toBe("game-not-visible");
      expect(status.permission).toBe("not-inspected");
      const receiver = (await invoke("receiver", "status")).result.receiver
        .snapshot;
      expect(receiver.backend).toBe("recording");
      expect(receiver.inputEnabled).toBe(false);
      expect((await invoke("wow", "capture-stop")).result.receipt).toBeNull();
    } finally {
      try {
        await invoke("service", "stop");
      } finally {
        // Windows may retain an executable mapping briefly after the service
        // stop reply. Require actual removal within a bounded cleanup window.
        const deadline = performance.now() + 3000;
        for (;;) {
          try {
            rmSync(directory, { recursive: true, force: true });
            break;
          } catch (error) {
            const code = (error as NodeJS.ErrnoException).code;
            if (
              process.platform !== "win32" ||
              !["EPERM", "EBUSY", "ENOTEMPTY"].includes(code ?? "") ||
              performance.now() >= deadline
            )
              throw error;
            await Bun.sleep(20);
          }
        }
      }
    }
  },
  45000,
);
