import { expect, test } from "bun:test";
import { resolve } from "node:path";
import {
  deleteProfileCommand,
  deleteProfileHelp,
} from "../apps/cli/src/delete-profile.ts";

const profileId = "e1000000-0000-0000-0000-000000000001";
const activeProfileId = "e1000000-0000-0000-0000-000000000002";
const opts = (defaultId: string = "none") =>
  new Map<string, string | true>([
    ["--operation-id", "delete-review"],
    ["--expected-revision", "2"],
    ["--profile-id", profileId],
    ["--active-profile-id", activeProfileId],
    ["--default-profile-id", defaultId],
  ]);

test("profile deletion requires explicit post-deletion selections and preserves null distinctly", () => {
  for (const defaultId of ["none", activeProfileId])
    expect(deleteProfileCommand(opts(defaultId))).toEqual({
      command: "configuration-delete-profile",
      operationId: "delete-review",
      expectedRevision: "2",
      profileId,
      activeProfileId,
      defaultProfileId: defaultId === "none" ? null : defaultId,
    });
  for (const key of [
    "--operation-id",
    "--expected-revision",
    "--profile-id",
    "--active-profile-id",
    "--default-profile-id",
  ]) {
    const missing = opts();
    missing.delete(key);
    expect(() => deleteProfileCommand(missing)).toThrow("missing_option");
  }
  const extra = opts();
  extra.set("--select", true);
  expect(() => deleteProfileCommand(extra)).toThrow(
    "invalid_configuration_option",
  );
  for (const defaultId of ["", "NONE", "null", "south"])
    expect(() => deleteProfileCommand(opts(defaultId))).toThrow(
      "invalid_configuration_request",
    );
  const invalid = opts();
  invalid.set("--expected-revision", "02");
  expect(() => deleteProfileCommand(invalid)).toThrow("invalid_counter");
});

test("scoped profile deletion help is offline and rejects ambiguous options", async () => {
  expect(deleteProfileHelp(["--json"])).toBeUndefined();
  expect(deleteProfileHelp(["--help"])?.activation).toContain(
    "installed input pin",
  );
  for (const values of [
    ["--help", "--help"],
    ["--help", "--profile-id", profileId],
  ])
    expect(() => deleteProfileHelp(values)).toThrow(
      "invalid_configuration_option",
    );
  const cli = resolve(import.meta.dir, "../apps/cli/src/main.ts");
  const child = Bun.spawn(
    [
      process.execPath,
      cli,
      "configuration",
      "delete-profile",
      "--help",
      "--json",
    ],
    { stdout: "pipe", stderr: "pipe" },
  );
  const [stdout, stderr, status] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  expect(status).toBe(0);
  expect(stderr).toBe("");
  expect(JSON.parse(stdout).result.kind).toBe(
    "configuration-delete-profile-help",
  );
});

test("delete CLI rejects duplicate, missing, unrelated and flag-looking selections before transport", async () => {
  const cli = resolve(import.meta.dir, "../apps/cli/src/main.ts");
  for (const [args, code] of [
    [
      ["--profile-id", profileId, "--profile-id", profileId],
      "invalid_arguments",
    ],
    [["--default-profile-id", "--select"], "missing_option_value"],
    [["--label=wrong"], "invalid_configuration_option"],
    [["--select"], "invalid_configuration_option"],
    [[], "missing_option"],
  ] as const) {
    const child = Bun.spawn(
      [process.execPath, cli, "configuration", "delete-profile", ...args],
      { stdout: "pipe", stderr: "pipe" },
    );
    const [stdout, stderr, status] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited,
    ]);
    expect(status).toBe(1);
    expect(stderr).toBe("");
    expect(JSON.parse(stdout).error).toBe(code);
  }
});

test("CLI deletion commits/replays while saved catalog and installed recording pin remain distinct", async () => {
  const { mkdtempSync, realpathSync, rmSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const parent = realpathSync(
    mkdtempSync(join(tmpdir(), "thumble-delete-cli-")),
  );
  const root = resolve(import.meta.dir, "..");
  const runtime = join(parent, "runtime");
  const receiver = join(
    root,
    "native/receiver/target/debug/thumble-rewrite-receiver" +
      (process.platform === "win32" ? ".exe" : ""),
  );
  const cli = resolve(root, "apps/cli/src/main.ts");
  const third = "e1000000-0000-0000-0000-000000000003";
  async function invoke(
    family: string,
    action: string,
    flags: string[] = [],
    failure?: string,
  ) {
    const child = Bun.spawn(
      [
        process.execPath,
        cli,
        family,
        action,
        "--runtime-dir",
        runtime,
        "--receiver",
        receiver,
        ...flags,
      ],
      { stdout: "pipe", stderr: "pipe" },
    );
    const [stdout, stderr, status] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited,
    ]);
    expect(stderr).toBe("");
    expect(status).toBe(failure ? 1 : 0);
    const value = JSON.parse(stdout);
    if (failure) {
      expect(value.error).toBe(failure);
      return;
    }
    expect(value.ok).toBe(true);
    return value.result;
  }
  const deletion = (
    operation: string,
    revision: string,
    target: string,
    active: string,
    fallback: string,
  ) => [
    "--operation-id",
    operation,
    "--expected-revision",
    revision,
    "--profile-id",
    target,
    "--active-profile-id",
    active,
    "--default-profile-id",
    fallback,
  ];
  try {
    await invoke("service", "start");
    await invoke("configuration", "initialize-starter", [
      "--operation-id",
      "delete-seed",
      "--expected-revision",
      "0",
      "--profile-id",
      profileId,
      "--name",
      "Delete review",
    ]);
    for (const [id, revision] of [
      [activeProfileId, "1"],
      [third, "2"],
    ])
      await invoke("configuration", "duplicate-profile", [
        "--operation-id",
        `duplicate-${revision}`,
        "--expected-revision",
        revision!,
        "--profile-id",
        profileId,
        "--new-profile-id",
        id!,
        "--name",
        "Remaining",
        "--keep-selection",
      ]);
    const catalog = await invoke("configuration", "list");
    await invoke("receiver", "activate-saved", [
      "--expected-receiver-revision",
      "0",
      "--expected-configuration-revision",
      "3",
      "--expected-source-hash",
      catalog.contentHash,
      "--profile-id",
      profileId,
    ]);
    const before = await invoke("receiver", "saved-status");
    expect(before.snapshot.active).toBe(true);
    expect(before.snapshot.backend).toBe("recording");
    expect(before.snapshot.inputEnabled).toBe(false);
    const inactive = await invoke(
      "configuration",
      "delete-profile",
      deletion("delete-inactive", "3", third, profileId, activeProfileId),
    );
    expect(inactive.receipt.affectedEntities).toEqual(["configuration", third]);
    expect(inactive.receipt.resultingRevision).toBe("4");
    const intent = deletion(
      "delete-installed",
      "4",
      profileId,
      activeProfileId,
      "none",
    );
    const first = await invoke("configuration", "delete-profile", intent);
    expect(first.receipt.resultingRevision).toBe("5");
    expect(first.replayed).toBe(false);
    const replay = await invoke("configuration", "delete-profile", intent);
    expect(replay.receipt).toEqual(first.receipt);
    expect(replay.replayed).toBe(true);
    const stale = await invoke(
      "configuration",
      "delete-profile",
      deletion("delete-stale", "4", activeProfileId, activeProfileId, "none"),
    );
    expect(stale).toEqual({
      version: 1,
      kind: "conflict",
      currentRevision: "5",
    });
    await invoke(
      "configuration",
      "delete-profile",
      deletion("delete-last", "5", activeProfileId, activeProfileId, "none"),
      "configuration_last_profile",
    );
    const after = await invoke("receiver", "saved-status");
    expect(after.savedBinding).toEqual(before.savedBinding);
    expect(after.snapshot.active).toBe(true);
    expect(after.snapshot.generation).toBe(before.snapshot.generation);
    expect(after.snapshot.revision).toBe(before.snapshot.revision);
    const remaining = await invoke("configuration", "list");
    expect(remaining.revision).toBe("5");
    expect(remaining.profiles.map((p: { id: string }) => p.id)).toEqual([
      activeProfileId,
    ]);
    await invoke("receiver", "release");
  } finally {
    try {
      await invoke("service", "stop");
    } catch {}
    for (let attempt = 0; attempt < 100; attempt++) {
      try {
        rmSync(parent, { recursive: true, force: true });
        break;
      } catch (error) {
        if (attempt === 99) throw error;
        await Bun.sleep(20);
      }
    }
  }
}, 30000);
