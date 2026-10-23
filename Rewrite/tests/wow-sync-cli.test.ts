import { expect, test } from "bun:test";
import {
  chmodSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { readEndpoint, request, requestWowSync } from "@thumble/client/local";
import { neutralGamepadState } from "@thumble/contracts";
import { atlasPNGFixture } from "./fixtures/wow-atlas-fixture.ts";
const root = resolve(import.meta.dir, ".."),
  cli = join(root, "apps/cli/src/main.ts"),
  receiver = join(
    root,
    "native/receiver/target/debug/thumble-rewrite-receiver" +
      (process.platform === "win32" ? ".exe" : ""),
  );
async function command(runtime: string, ...args: string[]) {
  const child = Bun.spawn(
    [
      process.execPath,
      cli,
      ...args,
      "--runtime-dir",
      runtime,
      "--receiver",
      receiver,
      "--json",
    ],
    { stdout: "pipe", stderr: "pipe" },
  );
  const timer = setTimeout(() => child.kill(), 9000);
  try {
    const [out, err] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited,
    ]);
    expect(err).toBe("");
    return JSON.parse(out);
  } finally {
    clearTimeout(timer);
  }
}
test.skipIf(process.platform === "win32")(
  "real CLI child-owned refresh/live jobs preserve default opt-in, sole SQLite ownership and active native recording heartbeat",
  async () => {
    const parent = realpathSync(
        mkdtempSync(join(tmpdir(), "thumble-wow-sync-")),
      ),
      runtime = join(parent, "runtime"),
      capture = join(parent, "capture"),
      profile = join(parent, "profile");
    const fixture = JSON.parse(
      readFileSync(join(root, "packages/fixtures/wow-live-v1.json"), "utf8"),
    );
    const liveModule = join(root, "packages/domain/src/wow-live.ts"),
      starter = join(root, "packages/domain/src/starter-configuration.ts");
    writeFileSync(
      capture,
      `#!${process.execPath}\nimport {wowLiveChecksum} from ${JSON.stringify(liveModule)};let buffer=Buffer.alloc(0),index=0;const frames=${JSON.stringify(fixture.frames)},png=${JSON.stringify(atlasPNGFixture().toString("base64"))};process.stdin.on('data',chunk=>{buffer=Buffer.concat([buffer,chunk]);while(buffer.length>=4&&buffer.length>=4+buffer.readUInt32BE()){const n=buffer.readUInt32BE(),request=JSON.parse(buffer.subarray(4,4+n));buffer=buffer.subarray(4+n);const bytes=Uint8Array.from(Buffer.from(frames[index%frames.length],'hex')),view=new DataView(bytes.buffer);view.setUint32(5,123+index++,true);const data=new Uint8Array(21+view.getUint16(17,true));data.set(bytes.subarray(0,21));data.set(bytes.subarray(25,25+data.length-21),21);view.setUint32(21,wowLiveChecksum(data),true);const body=Buffer.from(JSON.stringify({...request,command:'wow-capture-result',kind:'frame',frameBase64:Buffer.from(bytes).toString('base64'),atlasPNGBase64:png})),header=Buffer.alloc(4);header.writeUInt32BE(body.length);process.stdout.write(Buffer.concat([header,body]));}});`,
    );
    writeFileSync(
      profile,
      `#!${process.execPath}\nimport {createHash} from 'node:crypto';import {starterConfiguration} from ${JSON.stringify(starter)};let text='';process.stdin.on('data',chunk=>text+=chunk);process.stdin.on('end',()=>{const request=JSON.parse(text),snapshot=JSON.parse(request.snapshotJSON);setTimeout(()=>{const document=starterConfiguration(request.profileID,'Synthetic','1').set('/profiles/0/wowLive',JSON.stringify({characterID:snapshot.character.id,flavor:snapshot.client.flavor}));process.stdout.end(JSON.stringify({schemaVersion:2,sourceSHA256:createHash('sha256').update(request.existingProfileJSON).digest('hex'),beforeProfile:JSON.parse(request.existingProfileJSON),document:JSON.parse(document.text())}));},500);});`,
    );
    chmodSync(capture, 0o700);
    chmodSync(profile, 0o700);
    try {
      expect((await command(runtime, "service", "start")).ok).toBe(true);
      expect((await command(runtime, "wow", "sync-status")).result.state).toBe(
        "disabled",
      );
      expect(
        (
          await command(
            runtime,
            "wow",
            "refresh",
            "--operation-id",
            "off",
            "--expected-revision",
            "0",
          )
        ).error,
      ).toBe("wow_sync_not_enabled");
      await command(runtime, "service", "stop");
      for (
        let i = 0;
        i < 100 && existsSync(join(runtime, "endpoint.json"));
        i++
      )
        await Bun.sleep(20);
      expect(
        (
          await command(
            runtime,
            "service",
            "start",
            "--capture-helper",
            capture,
            "--wow-profile-helper",
            profile,
          )
        ).ok,
      ).toBe(true);
      const endpoint = readEndpoint(runtime, receiver);
      const active = await request(endpoint, {
        command: "activate",
        expectedRevision: "0",
        profileId: "test-native",
      });
      expect(active.receiver.snapshot.active).toBe(true);
      let sequence = 0,
        failed = false;
      const sample = async () => {
        try {
          await request(endpoint, {
            command: "sample",
            expectedGeneration: "1",
            sequence: String(sequence++),
            state: { ...neutralGamepadState(), buttons: ["south"] },
            allowRecordedInput: true,
          });
        } catch {
          failed = true;
        }
      };
      await sample();
      const samples = setInterval(() => void sample(), 100);
      try {
        const start = await command(
          runtime,
          "wow",
          "refresh",
          "--operation-id",
          "manual",
          "--expected-revision",
          "0",
        );
        expect(start.ok).toBe(true);
        expect(start.result.busy).toBe(true);
        expect(
          (
            await command(
              runtime,
              "configuration",
              "initialize-starter",
              "--operation-id",
              "competing",
              "--expected-revision",
              "0",
              "--profile-id",
              "aaaaaaaa-0000-0000-0000-000000000001",
              "--name",
              "Other",
            )
          ).error,
        ).toBe("configuration_owner_busy");
        let status = start.result;
        // Manual jobs have a30s product budget; this bounded test wait must not
        // mistake cold child compilation for synchronous pipeline completion.
        const completionDeadline = Date.now() + 8000;
        while (status.busy && Date.now() < completionDeadline) {
          await Bun.sleep(20);
          status = await requestWowSync(endpoint, {
            command: "wow-sync-status",
            operationId: "manual",
          });
        }
        expect(status.state).toBe("ready");
        expect(status.commitCount).toBe(1);
        expect(status.acknowledged).toBe(true);
        expect(status.busy).toBe(false);
        expect(JSON.stringify(status)).not.toContain("Base64");
        expect(JSON.stringify(status)).not.toContain("snapshotJSON");
        const catalog = await command(runtime, "configuration", "list");
        expect(catalog.result.revision).toBe("1");
        expect(catalog.result.profiles).toHaveLength(1);
        expect(failed).toBe(false);
        expect(sequence).toBeGreaterThan(4);
        expect(
          (await request(endpoint, { command: "status" })).receiver.snapshot
            .active,
        ).toBe(true);
        expect(
          (await request(endpoint, { command: "status" })).receiver.snapshot
            .generation,
        ).toBe("1");
        const live = await command(
          runtime,
          "wow",
          "sync-start",
          "--operation-id",
          "live",
          "--expected-revision",
          status.revision,
          "--expected-source-hash",
          status.contentHash,
        );
        expect(live.ok).toBe(true);
        const stopped = await command(
          runtime,
          "wow",
          "sync-stop",
          "--operation-id",
          "live",
        );
        expect(stopped.ok).toBe(true);
        for (
          let i = 0;
          i < 100 &&
          (
            await requestWowSync(endpoint, {
              command: "wow-sync-status",
              operationId: "live",
            })
          ).busy;
          i++
        )
          await Bun.sleep(20);
        expect(
          (
            await requestWowSync(endpoint, {
              command: "wow-sync-status",
              operationId: "live",
            })
          ).state,
        ).toBe("stopped");
        const mcp = Bun.spawn(
          [
            "node",
            join(root, "tooling/test-wow-mcp-node.mjs"),
            process.execPath,
            cli,
            receiver,
            runtime,
          ],
          { stdout: "pipe", stderr: "pipe" },
        );
        const [out, err, code] = await Promise.all([
          new Response(mcp.stdout).text(),
          new Response(mcp.stderr).text(),
          mcp.exited,
        ]);
        expect(err).toBe("");
        expect(code).toBe(0);
        expect(JSON.parse(out)).toEqual({
          ok: true,
          scenarios: 8,
          physicalInput: false,
        });
        expect(failed).toBe(false);
        expect(
          (await request(endpoint, { command: "status" })).receiver.snapshot
            .active,
        ).toBe(true);
      } finally {
        clearInterval(samples);
        await request(endpoint, { command: "release" });
      }
    } finally {
      await command(runtime, "service", "stop");
      for (
        let i = 0;
        i < 100 && existsSync(join(runtime, "endpoint.json"));
        i++
      )
        await Bun.sleep(20);
      rmSync(parent, { recursive: true, force: true });
    }
  },
  15000,
);

test.skipIf(process.platform === "win32")(
  "cached optical status never waits on a suspended configuration child",
  async () => {
    const { ConfigurationOwner } = await import(
      "../apps/service/src/configuration-owner.ts"
    );
    const { once } = await import("node:events");
    const parent = realpathSync(
      mkdtempSync(join(tmpdir(), "thumble-wow-status-")),
    );
    const owner = new ConfigurationOwner(receiver, join(parent, "runtime"), [
      process.execPath,
      cli,
    ]);
    let stopped = false;
    try {
      await owner.ready;
      owner.child.kill("SIGSTOP");
      stopped = true;
      let timer: ReturnType<typeof setTimeout> | undefined;
      try {
        const values = await Promise.race([
          Promise.all([
            owner.requestWowSync({
              command: "wow-sync-status",
              operationId: null,
            }),
            owner.requestWowCapture({ command: "wow-capture-status" }),
          ]),
          new Promise<never>((_, reject) => {
            timer = setTimeout(
              () => reject(Error("cached_status_waited_for_child")),
              150,
            );
          }),
        ]);
        expect(values[0].state).toBe("disabled");
        expect(values[1].state).toBe("disabled");
      } finally {
        clearTimeout(timer);
      }
    } finally {
      if (stopped) owner.child.kill("SIGCONT");
      const exited =
        owner.child.exitCode !== null
          ? Promise.resolve()
          : once(owner.child, "exit");
      owner.disconnect();
      const timer = setTimeout(() => owner.child.kill("SIGKILL"), 3000);
      try {
        await exited;
      } finally {
        clearTimeout(timer);
        rmSync(parent, { recursive: true, force: true });
      }
    }
  },
  5000,
);
