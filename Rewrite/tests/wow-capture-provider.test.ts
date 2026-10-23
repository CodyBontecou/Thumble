import { expectError } from "./helpers/rejection.ts";
import { spawn } from "node:child_process";
import { expect, test } from "bun:test";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  NativeWowCaptureProvider,
  captureHelperPath,
} from "../apps/service/src/wow-capture-provider.ts";
import { inspectWowCapturePermission } from "../apps/service/src/wow-capture-permission.ts";
const launch = (helper: string, args: readonly string[]) =>
  spawn(process.execPath, [helper, ...args], {
    stdio: ["pipe", "pipe", "pipe"] as ["pipe", "pipe", "pipe"],
    windowsHide: true,
  });
const request = JSON.stringify({
  version: 1,
  command: "wow-capture",
  source: 1,
  generation: "1",
  receipt: "1",
});
function helper(code: string) {
  const dir = mkdtempSync(join(tmpdir(), "thumble-capture-fake-")),
    path = join(dir, "helper");
  writeFileSync(path, `#!${process.execPath}\n${code}`);
  chmodSync(path, 0o700);
  return { path, clean: () => rmSync(dir, { recursive: true, force: true }) };
}
const framing = `function send(v){const b=Buffer.from(JSON.stringify(v)),h=Buffer.alloc(4);h.writeUInt32BE(b.length);process.stdout.write(Buffer.concat([h,b]));}`;
test("framed native provider handles partial header and one correlated response", async () => {
  const fake = helper(
    `process.stdin.once('data',()=>{const b=Buffer.from('ok'),h=Buffer.alloc(4);h.writeUInt32BE(2);process.stdout.write(h.subarray(0,2));setTimeout(()=>process.stdout.write(Buffer.concat([h.subarray(2),b])),10);});`,
  );
  const p = new NativeWowCaptureProvider(fake.path, "--capture", launch);
  try {
    expect(await p.capture(request)).toBe("ok");
  } finally {
    await p.stop();
    fake.clean();
  }
  expect(p.child.exitCode !== null || p.child.signalCode !== null).toBe(true);
});
test("native provider rejects oversized preallocation, unsolicited data, ASCII violation and child death", async () => {
  for (const code of [
    `const h=Buffer.alloc(4);h.writeUInt32BE(0xffffffff);process.stdout.write(h);`,
    `process.stdout.write(Buffer.from([0,0,0,1,255]));`,
    `process.exit(1);`,
    `process.stderr.write('x'.repeat(4097));`,
  ]) {
    const fake = helper(`process.stdin.once('data',()=>{${code}});`),
      p = new NativeWowCaptureProvider(fake.path, "--capture", launch);
    try {
      await expectError(p.capture(request), "wow_capture_provider_unavailable");
    } finally {
      await p.stop();
      fake.clean();
    }
  }
});
test("permission inspection/request are explicit bounded distinct commands", async () => {
  for (const status of [
    "authorized",
    "permission-required",
    "not-inspected",
    "unavailable",
  ] as const) {
    const fake = helper(
      framing +
        `send({version:1,command:process.argv[2]==='--request-permission'?'wow-capture-permission-result':'wow-capture-permission-status',status:${JSON.stringify(status)}});`,
    );
    try {
      for (const request of [false, true])
        expect(
          await inspectWowCapturePermission(fake.path, request, launch),
        ).toEqual({ kind: "wow-capture-permission", status });
    } finally {
      fake.clean();
    }
  }
  expect(() => captureHelperPath("relative")).toThrow(
    "wow_capture_helper_invalid",
  );
});

test("unexpected death after a reply invalidates scope while confirmed explicit stop does not", async () => {
  for (const explicit of [false, true]) {
    const fake = helper(
      `process.stdin.once('data',()=>{process.stdout.write(Buffer.from([0,0,0,2,111,107]));setTimeout(()=>process.exit(1),100);});`,
    );
    let failures = 0;
    const p = new NativeWowCaptureProvider(
      fake.path,
      "--capture",
      launch,
      () => failures++,
    );
    try {
      expect(await p.capture(request)).toBe("ok");
      if (explicit) await p.stop();
      else
        await new Promise<void>((resolve) =>
          p.child.once("close", () => resolve()),
        );
      expect(failures).toBe(explicit ? 0 : 1);
    } finally {
      await p.stop();
      fake.clean();
    }
  }
});

test("permission adapter rejects oversized header before payload and capture-shaped replies", async () => {
  for (const [code, error] of [
    [
      "const h=Buffer.alloc(4);h.writeUInt32BE(5000);process.stdout.write(h);",
      "wow_capture_provider_unavailable",
    ],
    [
      framing +
        "send({version:1,command:'wow-capture-result',kind:'frame',status:'authorized'});",
      "wow_capture_permission_invalid",
    ],
  ]) {
    const fake = helper(code!);
    try {
      await expectError(
        inspectWowCapturePermission(fake.path, false, launch),
        error!,
      );
    } finally {
      fake.clean();
    }
  }
});
