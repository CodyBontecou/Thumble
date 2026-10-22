import { expect, test } from "bun:test";
import { expectError } from "./helpers/rejection.ts";
import {
  copyFileSync,
  existsSync,
  mkdtempSync,
  readdirSync,
  realpathSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  decodeOutputCapabilities,
  type OutputCapabilities,
} from "@thumble/contracts/output-capabilities";
import { inspectOutputCapabilities } from "../apps/cli/src/output-doctor.ts";
const root = resolve(import.meta.dir, "..");
const receiver = join(
  root,
  `native/receiver/target/debug/thumble-rewrite-receiver${process.platform === "win32" ? ".exe" : ""}`,
);
const cli = join(root, "apps/cli/src/main.ts");
function valid(): OutputCapabilities {
  return {
    version: 1,
    kind: "output-capabilities",
    platform: "macos",
    backend: "recording",
    physicalOutputEnabled: false,
    runtimeIntegrated: false,
    macos: { dormantAdapterCompiled: false, signedClaim: "not-compiled" },
    windows: {
      candidate: "hidmaestro",
      candidateVersion: "2.0.3",
      upstreamCommit: "63cc6481f9e82fc8600bda8aaa65cb3271113a19",
      profile: "xbox-360-wired",
      sdkLinked: false,
      backendAvailable: false,
      driver: "not-inspected",
    },
    osDeviceAuthorization: "not-inspected",
    gameplayVerified: false,
  };
}
test("output capabilities distinguish dormant compilation, signed claims and unverified OS/driver authorization", () => {
  const v = valid();
  expect(decodeOutputCapabilities(v)).toEqual(v);
  expect(Object.isFrozen(decodeOutputCapabilities(v).windows)).toBe(true);
  for (const signedClaim of ["present", "absent", "inspection-failed"] as const)
    expect(
      decodeOutputCapabilities({
        ...v,
        macos: { dormantAdapterCompiled: true, signedClaim },
      }).macos.signedClaim,
    ).toBe(signedClaim);
  for (const platform of ["windows", "linux", "unsupported"] as const)
    expect(
      decodeOutputCapabilities({
        ...v,
        platform,
        macos: { dormantAdapterCompiled: false, signedClaim: "not-applicable" },
      }).platform,
    ).toBe(platform);
  for (const patch of [
    { version: 2 },
    { physicalOutputEnabled: true },
    { backend: "macos" },
    { runtimeIntegrated: true },
    { osDeviceAuthorization: "authorized" },
    { gameplayVerified: true },
    { token: "secret" },
    { platform: "darwin" },
    { macos: { dormantAdapterCompiled: true, signedClaim: "not-compiled" } },
    { macos: { dormantAdapterCompiled: false, signedClaim: "present" } },
    { windows: { ...v.windows, driver: "not-installed" } },
    { windows: { ...v.windows, sdkLinked: true } },
    { windows: { ...v.windows, backendAvailable: true } },
    { windows: { ...v.windows, candidateVersion: "latest" } },
    {
      platform: "windows",
      macos: { dormantAdapterCompiled: true, signedClaim: "present" },
    },
  ])
    expect(() => decodeOutputCapabilities({ ...v, ...patch })).toThrow();
});
test("output contract rejects getters, coercion, symbols and nested hidden provider fields without execution", () => {
  let reads = 0;
  const v = valid();
  const getter = { ...v };
  Object.defineProperty(getter, "backend", {
    get() {
      reads++;
      return "recording";
    },
  });
  const mac = { ...v.macos };
  Object.defineProperty(mac, "signedClaim", {
    get() {
      reads++;
      return "not-compiled";
    },
  });
  const coercion = {
    toString() {
      reads++;
      return "macos";
    },
  };
  for (const bad of [
    getter,
    { ...v, macos: mac },
    { ...v, platform: coercion },
    { ...v, macos: { dormantAdapterCompiled: true, signedClaim: coercion } },
    { ...v, [Symbol("hidden")]: 1 },
    { ...v, windows: { ...v.windows, path: "synthetic-private" } },
    Object.assign(Object.create({}), v),
  ])
    expect(() => decodeOutputCapabilities(bad)).toThrow();
  expect(reads).toBe(0);
});
test("native and CLI doctor work offline without creating runtime, trust, listeners or configuration", async () => {
  const parent = realpathSync(
    mkdtempSync(join(tmpdir(), "thumble-output-doctor-")),
  );
  try {
    const native = await inspectOutputCapabilities(receiver);
    expect(native.physicalOutputEnabled).toBe(false);
    expect(native.runtimeIntegrated).toBe(false);
    const child = Bun.spawn(
      [
        process.execPath,
        cli,
        "output",
        "doctor",
        "--receiver",
        receiver,
        "--json",
      ],
      { cwd: parent, stdout: "pipe", stderr: "pipe" },
    );
    const [out, err, code] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited,
    ]);
    expect(code).toBe(0);
    expect(err).toBe("");
    expect(JSON.parse(out).result).toEqual(native);
    expect(readdirSync(parent)).toEqual([]);
    const rejected = Bun.spawn(
      [
        process.execPath,
        cli,
        "output",
        "doctor",
        "--receiver",
        receiver,
        "--runtime-dir",
        join(parent, "absent", "runtime"),
      ],
      { stdout: "pipe", stderr: "pipe" },
    );
    const bad = JSON.parse(await new Response(rejected.stdout).text());
    expect(await rejected.exited).toBe(1);
    expect(bad.error).toBe("invalid_output_doctor_option");
    expect(readdirSync(parent)).toEqual([]);
    const direct = Bun.spawn([receiver, "output-capabilities", parent], {
      stdout: "pipe",
      stderr: "pipe",
    });
    expect(await direct.exited).toBe(1);
    expect(await new Response(direct.stdout).text()).toBe("");
    expect(await new Response(direct.stderr).text()).toContain(
      "invalid_output_doctor_arguments",
    );
  } finally {
    rmSync(parent, { recursive: true, force: true });
  }
});
test("both official MCP SDK eras expose read-only offline doctor without a running service", async () => {
  const parent = realpathSync(
      mkdtempSync(join(tmpdir(), "thumble-output-mcp-")),
    ),
    runtime = join(parent, "runtime");
  try {
    const child = Bun.spawn(
      [
        "node",
        join(root, "tooling/test-output-doctor-node.mjs"),
        process.execPath,
        cli,
        receiver,
        runtime,
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
    expect(JSON.parse(out)).toEqual({
      ok: true,
      scenarios: 2,
      serviceStarted: false,
    });
    expect(existsSync(runtime)).toBe(false);
  } finally {
    rmSync(parent, { recursive: true, force: true });
  }
}, 30000);
test("doctor adapter bounds native output, rejects duplicate JSON and sanitizes child failures", async () => {
  const parent = realpathSync(
      mkdtempSync(join(tmpdir(), "thumble-output-adversary-")),
    ),
    fixture = join(
      parent,
      `doctor-base${process.platform === "win32" ? ".exe" : ""}`,
    );
  try {
    const build = Bun.spawn(
      [
        process.execPath,
        "build",
        "--compile",
        join(import.meta.dir, "fixtures/output-doctor-native.ts"),
        "--outfile",
        fixture,
      ],
      { stdout: "ignore", stderr: "pipe" },
    );
    const errors = await new Response(build.stderr).text();
    expect(await build.exited).toBe(0);
    expect(errors).toBe("");
    for (const [mode, error] of [
      ["oversize", "output_doctor_response_too_large"],
      ["stderr", "output_doctor_unavailable"],
      ["invalid", "output_doctor_response_invalid"],
      ["timeout", "output_doctor_timeout"],
    ] as const) {
      const path = join(
        parent,
        `doctor-${mode}${process.platform === "win32" ? ".exe" : ""}`,
      );
      copyFileSync(fixture, path);
      await expectError(inspectOutputCapabilities(path), error);
    }
  } finally {
    rmSync(parent, { recursive: true, force: true });
  }
}, 30000);
