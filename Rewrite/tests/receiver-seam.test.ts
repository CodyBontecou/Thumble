import { expectError } from "./helpers/rejection.ts";
import { expect, test } from "bun:test";
import {
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
  statSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createConnection } from "node:net";
import { readEndpoint, request } from "@thumble/client/local";
import { neutralGamepadState, type GamepadState } from "@thumble/contracts";
import { parseStrictJson } from "@thumble/contracts/receiver";
import { secureDirectory } from "../apps/service/src/service.ts";
const root = resolve(import.meta.dir, "..");
const executable = resolve(
  root,
  `native/receiver/target/debug/thumble-rewrite-receiver${process.platform === "win32" ? ".exe" : ""}`,
);
const cli = resolve(root, "apps/cli/src/main.ts");
const neutral = "0014000000000000000000000000000000000000";
const held: GamepadState = {
  ...neutralGamepadState(),
  buttons: ["south"],
  leftTrigger: 1,
  rightTrigger: 1,
};
async function command(
  directory: string,
  ...args: string[]
): Promise<{ code: number; value: any }> {
  const child = Bun.spawn(
    [
      process.execPath,
      cli,
      ...args,
      "--runtime-dir",
      directory,
      "--receiver",
      executable,
      "--json",
    ],
    { stdout: "pipe", stderr: "pipe" },
  );
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  if (stderr.trim()) throw new Error("CLI wrote unexpected stderr");
  return { code, value: parseStrictJson(stdout) };
}
async function waitFor(
  predicate: () => boolean | Promise<boolean>,
  limit = 3000,
): Promise<void> {
  const deadline = Date.now() + limit;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await Bun.sleep(20);
  }
  throw new Error("condition_timeout");
}
function events(path: string): Array<{ reportHex: string; reason: string }> {
  try {
    return readFileSync(path, "utf8")
      .trim()
      .split("\n")
      .filter(Boolean)
      .map((line) => JSON.parse(line));
  } catch {
    return [];
  }
}
async function fixture(
  run: (directory: string, parent: string) => Promise<void>,
): Promise<void> {
  const parent = realpathSync(mkdtempSync(join(tmpdir(), "thumble-m2-"))),
    directory = join(parent, "runtime");
  try {
    await run(directory, parent);
  } finally {
    try {
      const endpoint = readEndpoint(directory, executable);
      await request(endpoint, { command: "stop" });
    } catch {}
    for (let n = 0; n < 50; n++) {
      try {
        rmSync(parent, { recursive: true, force: true });
        break;
      } catch {
        await Bun.sleep(20);
      }
    }
  }
}

test("service survives CLI exit; CAS activation, replay, precision, full-state repair and generation barriers", async () => {
  await fixture(async (directory) => {
    const started = await command(directory, "service", "start");
    expect(started.code).toBe(0);
    expect(started.value.result.receiver.snapshot.inputEnabled).toBe(false);
    const endpoint = readEndpoint(directory, executable);
    expect(endpoint.servicePid).not.toBe(process.pid);
    if (process.platform !== "win32") {
      expect(statSync(directory).mode & 0o777).toBe(0o700);
      expect(statSync(join(directory, "endpoint.json")).mode & 0o777).toBe(
        0o600,
      );
    }
    const initial = await request(endpoint, { command: "status" });
    expect(initial.receiver.snapshot.active).toBe(false);
    const active = await request(endpoint, {
      command: "activate",
      expectedRevision: "0",
      profileId: "profile-A",
    });
    expect(active.receiver.snapshot.generation).toBe("1");
    await expectError(
      request(endpoint, {
        command: "activate",
        expectedRevision: "0",
        profileId: "stale",
      }),
      "revision_conflict",
    );
    const sample = await request(endpoint, {
      command: "sample",
      expectedGeneration: "1",
      sequence: "9007199254740993",
      state: held,
      allowRecordedInput: true,
    });
    expect(sample.receiver.snapshot.sequence).toBe("9007199254740993");
    expect(sample.receiver.snapshot.reportHex).not.toBe(neutral);
    await expectError(
      request(endpoint, {
        command: "sample",
        expectedGeneration: "1",
        sequence: "9007199254740993",
        state: held,
        allowRecordedInput: true,
      }),
      "replayed_sample",
    );
    const repair = await request(endpoint, {
      command: "sample",
      expectedGeneration: "1",
      sequence: "9007199254740994",
      state: neutralGamepadState(),
      allowRecordedInput: true,
    });
    expect(repair.receiver.snapshot.reportHex).toBe(neutral);
    const switched = await request(endpoint, {
      command: "activate",
      expectedRevision: "1",
      profileId: "profile-B",
    });
    expect(switched.receiver.snapshot.reportHex).toBe(neutral);
    expect(switched.receiver.snapshot.generation).toBe("2");
    await expectError(
      request(endpoint, {
        command: "sample",
        expectedGeneration: "1",
        sequence: "9007199254740995",
        state: held,
        allowRecordedInput: true,
      }),
      "inactive_generation",
    );
    await request(endpoint, {
      command: "sample",
      expectedGeneration: "2",
      sequence: "0",
      state: held,
      allowRecordedInput: true,
    });
    const released = await request(endpoint, { command: "release" });
    expect(released.receiver.snapshot.active).toBe(false);
    expect(released.receiver.snapshot.reportHex).toBe(neutral);
    const stopped = await command(directory, "service", "stop");
    expect(stopped.code).toBe(0);
    expect(stopped.value.result.receiver.snapshot.reportHex).toBe(neutral);
    await waitFor(() =>
      events(endpoint.recordingLog).some(
        (event) => event.reason === "process_exit",
      ),
    );
    const restarted = await command(directory, "service", "start");
    expect(restarted.code).toBe(0);
    expect(restarted.value.result.receiver.snapshot.active).toBe(false);
    expect(restarted.value.result.receiver.snapshot.generation).toBe("0");
    expect(restarted.value.result.receiver.snapshot.reportHex).toBe(neutral);
  });
}, 20000);

test("service death neutralizes the independent receiver within the owner lease", async () => {
  await fixture(async (directory) => {
    expect((await command(directory, "service", "start")).code).toBe(0);
    const endpoint = readEndpoint(directory, executable);
    await request(endpoint, {
      command: "activate",
      expectedRevision: "0",
      profileId: "fault-test",
    });
    await request(endpoint, {
      command: "sample",
      expectedGeneration: "1",
      sequence: "1",
      state: held,
      allowRecordedInput: true,
    });
    const killedAt = performance.now();
    process.kill(endpoint.servicePid, "SIGKILL");
    await waitFor(
      () =>
        events(endpoint.recordingLog).some(
          (event) => event.reason === "owner_disconnected",
        ),
      1500,
    );
    expect(performance.now() - killedAt).toBeLessThan(1000);
    expect(events(endpoint.recordingLog).at(-1)?.reportHex).toBe(neutral);
    await waitFor(() =>
      events(endpoint.recordingLog).some(
        (event) => event.reason === "process_exit",
      ),
    );
    const restarted = await command(directory, "service", "start");
    expect(restarted.code).toBe(0);
    expect(restarted.value.result.receiver.snapshot.active).toBe(false);
    await expectError(
      request(readEndpoint(directory, executable), {
        command: "sample",
        expectedGeneration: "1",
        sequence: "2",
        state: held,
        allowRecordedInput: true,
      }),
      "inactive_generation",
    );
  });
}, 20000);

test("JS stalls do not stall native expiry", async () => {
  await fixture(async (directory) => {
    secureDirectory(executable, directory);
    const log = join(directory, "stalled.jsonl");
    const child = Bun.spawn(
      [
        process.execPath,
        resolve(root, "tests/fixtures/stalled-owner.ts"),
        executable,
        directory,
        log,
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
    const status = JSON.parse(out);
    expect(status.active).toBe(false);
    expect(status.reportHex).toBe(neutral);
    expect(["lease_expired", "input_expired"]).toContain(
      status.lastReleaseReason,
    );
  });
}, 10000);

test("only one service owns a runtime directory; unrelated state is refused", async () => {
  await fixture(async (directory, parent) => {
    const results = await Promise.all([
      command(directory, "service", "start"),
      command(directory, "service", "start"),
    ]);
    expect(results.some((result) => result.code === 0)).toBe(true);
    const successful = results.filter((result) => result.code === 0);
    expect(
      new Set(
        successful.map((result) => result.value.result.service.instanceId),
      ).size,
    ).toBe(1);
    const existing = join(parent, "existing");
    await Bun.write(join(existing, "state.json"), "unrelated");
    const refused = await command(existing, "service", "start");
    expect(refused.code).toBe(1);
    expect(readFileSync(join(existing, "state.json"), "utf8")).toBe(
      "unrelated",
    );
  });
}, 20000);

test("local auth, input opt-in and duplicate JSON rejection never activate outputs", async () => {
  await fixture(async (directory, parent) => {
    expect((await command(directory, "service", "start")).code).toBe(0);
    const endpoint = readEndpoint(directory, executable);
    await expectError(
      request({ ...endpoint, token: "0".repeat(64) }, { command: "release" }),
      "unauthorized",
    );
    const file = join(parent, "sample.json");
    writeFileSync(file, JSON.stringify(held));
    const denied = await command(
      directory,
      "receiver",
      "sample",
      "--expected-generation",
      "0",
      "--sequence",
      "1",
      "--state-file",
      file,
    );
    expect(denied.code).toBe(1);
    expect(denied.value.error).toBe("input_opt_in_required");
    const frame = `{"version":1,"requestId":"bad","token":"${endpoint.token}","body":{"command":"release","command":"status"}}\n`;
    const reply = await new Promise<string>((resolve, reject) => {
      const socket = createConnection(
        { host: "127.0.0.1", port: endpoint.port },
        () => socket.write(frame),
      );
      let data = "";
      socket.on("data", (chunk) => (data += chunk));
      socket.on("end", () => resolve(data));
      socket.on("error", reject);
    });
    expect(JSON.parse(reply).ok).toBe(false);
    expect(
      (await request(endpoint, { command: "status" })).receiver.snapshot.active,
    ).toBe(false);
  });
}, 15000);

test("strict JSON rejects escaped duplicate keys, excessive nesting and malformed values", () => {
  for (const text of [
    '{"a":1,"\\u0061":2}',
    "[".repeat(18) + "0" + "]".repeat(18),
    '{"x":01}',
    "[1,]",
    '{"x":NaN}',
  ])
    expect(() => parseStrictJson(text)).toThrow();
  expect(
    parseStrictJson('{"text":"\\\" bracket }","values":[null,true,1.25e2]}'),
  ).toEqual({ text: '" bracket }', values: [null, true, 125] });
});
