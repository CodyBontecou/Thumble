import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  decodeHostIdentity,
  type HostIdentity,
} from "@thumble/contracts/host-identity";
import { parseStrictJson, record } from "@thumble/contracts/receiver";
const root = resolve(import.meta.dir, "..");
const receiver = resolve(
  root,
  `native/receiver/target/debug/thumble-rewrite-receiver${process.platform === "win32" ? ".exe" : ""}`,
);
async function invoke(directory: string, action: string) {
  const child = Bun.spawn(
    [
      process.execPath,
      resolve(root, "apps/cli/src/main.ts"),
      "identity",
      action,
      "--identity-dir",
      directory,
      "--receiver",
      receiver,
      "--json",
    ],
    { stdout: "pipe", stderr: "pipe" },
  );
  const [out, err, code] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  expect(err).toBe("");
  return { code, value: record(parseStrictJson(out)) };
}
test("public identity contract rejects credentials, unsupported policy and executable object fields", () => {
  const valid: HostIdentity = {
    version: 1,
    certificatePin: "a".repeat(64),
    serverName: "thumble-rewrite.local",
    networkEnabled: false,
    inputEnabled: false,
  };
  expect(decodeHostIdentity(valid)).toEqual(valid);
  expect(Object.isFrozen(decodeHostIdentity(valid))).toBe(true);
  for (const bad of [
    { ...valid, version: 2 },
    { ...valid, certificatePin: "A".repeat(64) },
    { ...valid, serverName: "other.local" },
    { ...valid, networkEnabled: true },
    { ...valid, inputEnabled: true },
    { ...valid, key: "must-never-cross-native-boundary" },
    Object.assign(Object.create({}), valid),
    { ...valid, [Symbol("extra")]: 1 },
  ])
    expect(() => decodeHostIdentity(bad)).toThrow();
  let reads = 0;
  const getter = { ...valid };
  Object.defineProperty(getter, "certificatePin", {
    get() {
      reads++;
      return valid.certificatePin;
    },
  });
  expect(() => decodeHostIdentity(getter)).toThrow();
  expect(reads).toBe(0);
});
test("headless identity initialize/show survives separate native processes without exporting private keys", async () => {
  const parent = realpathSync(
      mkdtempSync(join(tmpdir(), "thumble-identity-cli-")),
    ),
    directory = join(parent, "identity");
  try {
    const missing = await invoke(directory, "show");
    expect(missing.code).toBe(1);
    expect(missing.value.error).toBe("host_identity_not_initialized");
    expect(existsSync(directory)).toBe(false);
    const first = await invoke(directory, "initialize");
    expect(first.code).toBe(0);
    const metadata = decodeHostIdentity(first.value.result);
    const record = readFileSync(join(directory, "identity.bin"));
    expect(record.subarray(0, 8)).toEqual(
      Buffer.from([84, 72, 73, 68, 49, 0, 0, 0]),
    );
    const certLength = record.readUInt32LE(8),
      keyLength = record.readUInt32LE(12);
    expect(record.length).toBe(16 + certLength + keyLength);
    expect(
      createHash("sha256")
        .update(record.subarray(16, 16 + certLength))
        .digest("hex"),
    ).toBe(metadata.certificatePin);
    expect(JSON.stringify(first.value)).not.toContain(
      record.subarray(16 + certLength).toString("hex"),
    );
    const shown = await invoke(directory, "show"),
      restarted = await invoke(directory, "initialize");
    expect(shown.code).toBe(0);
    expect(restarted.code).toBe(0);
    expect(shown.value).toEqual(first.value);
    expect(restarted.value).toEqual(first.value);
    expect(readFileSync(join(directory, "identity.bin"))).toEqual(record);
    expect(existsSync(join(directory, "endpoint.json"))).toBe(false);
    writeFileSync(
      join(directory, "identity.bin"),
      Buffer.from("truncated-record"),
    );
    const corrupt = await invoke(directory, "initialize");
    expect(corrupt.code).toBe(1);
    expect(corrupt.value.error).toBe("host_identity_invalid");
    expect(readFileSync(join(directory, "identity.bin"), "utf8")).toBe(
      "truncated-record",
    );
  } finally {
    rmSync(parent, { recursive: true, force: true });
  }
}, 10000);
