import { expect, test } from "bun:test";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  controlLabelCommand,
  controlLabelHelp,
} from "../apps/cli/src/control-label.ts";

const profileId = "e1000000-0000-0000-0000-000000000001";
const controlId = "ce000000-0000-0000-0000-000000000001";
const options = (label: string | null) =>
  new Map<string, string | true>([
    ["--operation-id", "review-label"],
    ["--expected-revision", "1"],
    ["--profile-id", profileId],
    ["--control-id", controlId],
    label === null ? ["--clear-label", true] : ["--label", label],
  ]);

test("control label CLI intent preserves Unicode, explicit blank and clear distinctly", () => {
  for (const label of [
    "Move 🎮",
    "",
    "  exact whitespace  ",
    "--clear-label",
    "🦊".repeat(32),
    null,
  ]) {
    expect(controlLabelCommand(options(label))).toEqual({
      command: "configuration-set-control-label",
      operationId: "review-label",
      expectedRevision: "1",
      profileId,
      controlId,
      label,
    });
  }
});

test("control label CLI requires one explicit label intent and delegates strict typed bounds", () => {
  const missing = options(null);
  missing.delete("--clear-label");
  expect(() => controlLabelCommand(missing)).toThrow(
    "configuration_label_intent_required",
  );
  const both = options("");
  both.set("--clear-label", true);
  expect(() => controlLabelCommand(both)).toThrow(
    "configuration_label_intent_required",
  );
  const extra = options("Label");
  extra.set("--expected-source-hash", "0".repeat(64));
  expect(() => controlLabelCommand(extra)).toThrow(
    "invalid_configuration_option",
  );
  for (const label of ["🦊".repeat(33), "\ud800"])
    expect(() => controlLabelCommand(options(label))).toThrow(
      "invalid_configuration_request",
    );
  const invalid = options("Label");
  invalid.set("--control-id", "south");
  expect(() => controlLabelCommand(invalid)).toThrow(
    "invalid_configuration_request",
  );
});

test("scoped label help never needs an endpoint and rejects unrelated options", async () => {
  expect(controlLabelHelp(["--json"])).toBeUndefined();
  expect(controlLabelHelp(["--help"])?.command).toBe(
    "configuration set-control-label",
  );
  for (const values of [
    ["--help", "--help"],
    ["--help", "--clear-label"],
    ["--help", "--runtime-dir", "private"],
  ])
    expect(() => controlLabelHelp(values)).toThrow(
      "invalid_configuration_option",
    );
  const cli = resolve(import.meta.dir, "../apps/cli/src/main.ts");
  const child = Bun.spawn(
    [
      process.execPath,
      cli,
      "configuration",
      "set-control-label",
      "--help",
      "--json",
    ],
    { stdout: "pipe", stderr: "pipe" },
  );
  const [text, error, status] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  expect(status).toBe(0);
  expect(error).toBe("");
  const result = JSON.parse(text);
  expect(result.ok).toBe(true);
  expect(result.result.kind).toBe("configuration-control-label-help");
  expect(result.result.clear).toContain("generated label");
});

test("CLI accepts empty/equal-label syntax and rejects duplicate or ambiguous intent before transport", async () => {
  const parent = realpathSync(
    mkdtempSync(join(tmpdir(), "thumble-label-cli-options-")),
  );
  const cli = resolve(import.meta.dir, "../apps/cli/src/main.ts");
  try {
    for (const values of [
      ["--label", ""],
      ["--label="],
      ["--label=--flag-looking"],
    ]) {
      const child = Bun.spawn(
        [
          process.execPath,
          cli,
          "configuration",
          "set-control-label",
          "--runtime-dir",
          parent,
          "--operation-id",
          "syntax",
          "--expected-revision",
          "1",
          "--profile-id",
          profileId,
          "--control-id",
          controlId,
          ...values,
        ],
        { stdout: "pipe", stderr: "pipe" },
      );
      const [text, error, status] = await Promise.all([
        new Response(child.stdout).text(),
        new Response(child.stderr).text(),
        child.exited,
      ]);
      expect(status).toBe(1);
      expect(error).toBe("");
      expect(JSON.parse(text).error).toBe("command_failed");
    }
    for (const [values, expected] of [
      [["--label=a", "--label=b"], "invalid_arguments"],
      [["--label", "", "--clear-label"], "configuration_label_intent_required"],
    ] as const) {
      const child = Bun.spawn(
        [
          process.execPath,
          cli,
          "configuration",
          "set-control-label",
          ...values,
        ],
        { stdout: "pipe", stderr: "pipe" },
      );
      const [text, error, status] = await Promise.all([
        new Response(child.stdout).text(),
        new Response(child.stderr).text(),
        child.exited,
      ]);
      expect(status).toBe(1);
      expect(error).toBe("");
      expect(JSON.parse(text).error).toBe(expected);
    }
    const unrelated = Bun.spawn(
      [process.execPath, cli, "receiver", "status", "--label=ignored"],
      { stdout: "pipe", stderr: "pipe" },
    );
    const [unrelatedText, unrelatedError, unrelatedStatus] = await Promise.all([
      new Response(unrelated.stdout).text(),
      new Response(unrelated.stderr).text(),
      unrelated.exited,
    ]);
    expect(unrelatedStatus).toBe(1);
    expect(unrelatedError).toBe("");
    expect(JSON.parse(unrelatedText).error).toBe(
      "invalid_configuration_option",
    );
  } finally {
    rmSync(parent, { recursive: true, force: true });
  }
});

test("actual CLI saved-label CAS, durable replay and clear preserve the active recording generation", async () => {
  const parent = realpathSync(
    mkdtempSync(join(tmpdir(), "thumble-label-cli-service-")),
  );
  const runtime = join(parent, "runtime");
  const root = resolve(import.meta.dir, "..");
  const cli = join(root, "apps/cli/src/main.ts");
  const receiver = join(
    root,
    "native/receiver/target/debug/thumble-rewrite-receiver" +
      (process.platform === "win32" ? ".exe" : ""),
  );
  async function invoke(family: string, action: string, ...values: string[]) {
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
        ...values,
      ],
      { stdout: "pipe", stderr: "pipe" },
    );
    const [text, error, status] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited,
    ]);
    expect(error).toBe("");
    expect(status).toBe(0);
    const reply = JSON.parse(text);
    expect(reply.ok).toBe(true);
    return reply.result;
  }
  const intent = [
    "--operation-id",
    "cli-label-one",
    "--expected-revision",
    "1",
    "--profile-id",
    profileId,
    "--control-id",
    controlId,
    "--label",
    "Move 🎮",
  ];
  try {
    await invoke("service", "start");
    await invoke(
      "configuration",
      "initialize-starter",
      "--operation-id",
      "cli-label-starter",
      "--expected-revision",
      "0",
      "--profile-id",
      profileId,
      "--name",
      "Label review",
    );
    const catalog = await invoke("configuration", "list");
    await invoke(
      "receiver",
      "activate-saved",
      "--expected-receiver-revision",
      "0",
      "--expected-configuration-revision",
      "1",
      "--expected-source-hash",
      catalog.contentHash,
      "--profile-id",
      profileId,
    );
    const before = await invoke("receiver", "saved-status");
    expect(before.snapshot.backend).toBe("recording");
    expect(before.snapshot.inputEnabled).toBe(false);
    expect(before.snapshot.active).toBe(true);
    const first = await invoke("configuration", "set-control-label", ...intent);
    expect(first.kind).toBe("committed");
    expect(first.receipt.resultingRevision).toBe("2");
    expect(first.receipt.affectedEntities).toEqual([profileId, controlId]);
    expect(first.replayed).toBe(false);
    const replay = await invoke(
      "configuration",
      "set-control-label",
      ...intent,
    );
    expect(replay.receipt).toEqual(first.receipt);
    expect(replay.replayed).toBe(true);
    const conflict = await invoke(
      "configuration",
      "set-control-label",
      "--operation-id",
      "cli-label-stale",
      "--expected-revision",
      "1",
      "--profile-id",
      profileId,
      "--control-id",
      controlId,
      "--label",
      "Wrong stale label",
    );
    expect(conflict).toEqual({
      version: 1,
      kind: "conflict",
      currentRevision: "2",
    });
    const clear = await invoke(
      "configuration",
      "set-control-label",
      "--operation-id",
      "cli-label-clear",
      "--expected-revision",
      "2",
      "--profile-id",
      profileId,
      "--control-id",
      controlId,
      "--clear-label",
    );
    expect(clear.receipt.resultingRevision).toBe("3");
    const blank = await invoke(
      "configuration",
      "set-control-label",
      "--operation-id",
      "cli-label-blank",
      "--expected-revision",
      "3",
      "--profile-id",
      profileId,
      "--control-id",
      controlId,
      "--label",
      "",
    );
    expect(blank.receipt.resultingRevision).toBe("4");
    const after = await invoke("receiver", "saved-status");
    expect(after.savedBinding).toEqual(before.savedBinding);
    expect(after.snapshot.active).toBe(true);
    expect(after.snapshot.generation).toBe(before.snapshot.generation);
    expect(after.snapshot.revision).toBe(before.snapshot.revision);
    expect((await invoke("configuration", "list")).revision).toBe("4");
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
