import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";

import {
  readEndpoint,
  readStateFile,
  request,
  runtimeDirectory,
} from "@thumble/client/local";
import {
  decodeLocalCommand,
  type LocalCommand,
} from "@thumble/contracts/receiver";
import { secureDirectory, serve } from "@thumble/service";
const source = process.argv[1]?.endsWith(".ts") === true;
const arguments_ = process.argv.slice(2);
const extension = process.platform === "win32" ? ".exe" : "";
function options(values: string[]): Map<string, string | true> {
  const result = new Map<string, string | true>();
  for (let i = 0; i < values.length; i++) {
    const key = values[i]!;
    if (!key.startsWith("--") || result.has(key))
      throw new Error("invalid_arguments");
    if (["--json", "--allow-recorded-input"].includes(key)) {
      result.set(key, true);
      continue;
    }
    if (
      ![
        "--runtime-dir",
        "--receiver",
        "--profile-id",
        "--expected-revision",
        "--expected-generation",
        "--sequence",
        "--state-file",
      ].includes(key)
    )
      throw new Error("unknown_option");
    const value = values[++i];
    if (!value || value.startsWith("--"))
      throw new Error("missing_option_value");
    result.set(key, value);
  }
  return result;
}
function required(opts: Map<string, string | true>, key: string): string {
  const value = opts.get(key);
  if (typeof value !== "string") throw new Error("missing_option");
  return value;
}
async function main(): Promise<unknown> {
  const [family, action, ...rest] = arguments_;
  const opts = options(rest);
  const raw = opts.get("--runtime-dir");
  const root = runtimeDirectory(
    typeof raw === "string" ? raw : join(homedir(), ".thumble-rewrite-runtime"),
  );
  const configured = opts.get("--receiver");
  const receiver =
    typeof configured === "string"
      ? resolve(configured)
      : source
        ? resolve(
            import.meta.dir,
            `../../../native/receiver/target/debug/thumble-rewrite-receiver${extension}`,
          )
        : join(
            dirname(process.execPath),
            `thumble-rewrite-receiver${extension}`,
          );
  if (family === "__service" && action === "run") {
    await serve(receiver, root);
    return undefined;
  }
  if (family === "service" && action === "run") {
    await serve(receiver, root);
    return undefined;
  }
  if (family === "service" && action === "start") {
    secureDirectory(receiver, root);
    try {
      return await request(readEndpoint(root, receiver), { command: "status" });
    } catch {}
    const launcher = source
      ? [process.execPath, process.argv[1]!]
      : [process.execPath];
    const child = spawn(
      launcher[0]!,
      [
        ...launcher.slice(1),
        "__service",
        "run",
        "--runtime-dir",
        root,
        "--receiver",
        receiver,
      ],
      { detached: true, stdio: "ignore", windowsHide: true },
    );
    child.on("error", () => {});
    child.unref();
    const deadline = Date.now() + 5000;
    do {
      try {
        return await request(readEndpoint(root, receiver), {
          command: "status",
        });
      } catch {}
      await Bun.sleep(50);
    } while (Date.now() < deadline);
    throw new Error("service_start_failed");
  }
  let command: LocalCommand;
  if ((family === "service" || family === "receiver") && action === "status")
    command = { command: "status" };
  else if (family === "service" && action === "stop")
    command = { command: "stop" };
  else if (family === "receiver" && action === "release")
    command = { command: "release" };
  else if (family === "receiver" && action === "activate")
    command = decodeLocalCommand({
      command: "activate",
      expectedRevision: required(opts, "--expected-revision"),
      profileId: required(opts, "--profile-id"),
    });
  else if (family === "receiver" && action === "sample") {
    const file = required(opts, "--state-file");

    command = decodeLocalCommand({
      command: "sample",
      expectedGeneration: required(opts, "--expected-generation"),
      sequence: required(opts, "--sequence"),
      state: readStateFile(file),
      allowRecordedInput: opts.get("--allow-recorded-input") === true,
    });
  } else throw new Error("unsupported_command");
  return await request(readEndpoint(root, receiver), command);
}
try {
  const result = await main();
  if (result !== undefined)
    console.log(JSON.stringify({ version: 1, ok: true, result }));
} catch (error) {
  const message = error instanceof Error ? error.message : "command_failed";
  const code = /^[a-z_]+$/.test(message) ? message : "command_failed";
  console.log(JSON.stringify({ version: 1, ok: false, error: code }));
  process.exit(1);
}
