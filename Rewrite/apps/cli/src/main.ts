import { outputLaunchOptions } from "./output-launch.ts";
import { runWowCaptureOwner } from "@thumble/service/wow-capture-owner-process";
import { inspectWowCapturePermission } from "@thumble/service/wow-capture-permission";
import { decodeWowCaptureCommand } from "@thumble/contracts/wow-capture-control";
import { decodeSavedRuntimeCommand } from "@thumble/contracts/saved-runtime";
import { inspectOutputCapabilities } from "./output-doctor.ts";
import { runConfigurationOwner } from "@thumble/service/configuration-owner-process";
import { inspectConfigurationFile } from "@thumble/service/configuration-files";
import { decodeConfigurationCommand } from "@thumble/contracts/configuration";
import { startMcp } from "./mcp.ts";
import { decodeHostIdentity } from "@thumble/contracts/host-identity";
import { spawn, spawnSync } from "node:child_process";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, resolve } from "node:path";

import {
  readEndpoint,
  readStateFile,
  request,
  requestPairing,
  requestConfiguration,
  requestSavedRuntime,
  requestWowCapture,
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
    if (
      [
        "--json",
        "--allow-physical-output",
        "--allow-recorded-input",
        "--reveal-secret",
        "--allow-configuration-write",
        "--allow-wow-capture",
        "--select",
        "--keep-selection",
      ].includes(key)
    ) {
      result.set(key, true);
      continue;
    }
    if (
      ![
        "--file",
        "--output",
        "--operation-id",
        "--expected-source-hash",
        "--name",
        "--offset",
        "--identity-dir",
        "--bind-address",
        "--advertise-host",
        "--phone-id",
        "--runtime-dir",
        "--receiver",
        "--capture-helper",
        "--source",
        "--profile-id",
        "--new-profile-id",
        "--active-profile-id",
        "--default-profile-id",
        "--expected-revision",
        "--expected-receiver-revision",
        "--expected-configuration-revision",
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
function nativeIdentity(
  receiver: string,
  directory: string,
  action: "initialize" | "show",
) {
  const child = spawnSync(receiver, [`host-identity-${action}`, directory], {
    encoding: "utf8",
    timeout: 5000,
    maxBuffer: 4096,
    windowsHide: true,
  });
  if (child.error || child.status !== 0) {
    if (
      child.error &&
      "code" in child.error &&
      child.error.code === "ETIMEDOUT"
    )
      throw new Error("host_identity_startup_timed_out");
    const code = child.stderr?.trim();
    throw new Error(
      code && /^[a-z_]+$/.test(code) ? code : "host_identity_unavailable",
    );
  }
  return decodeHostIdentity(JSON.parse(child.stdout));
}
async function main(): Promise<unknown> {
  const [family, action, ...rest] = arguments_;
  const opts = options(rest);
  if (
    (opts.has("--output") || opts.has("--allow-physical-output")) &&
    !(
      (family === "service" && (action === "start" || action === "run")) ||
      (family === "__service" && action === "run")
    )
  )
    throw new Error("invalid_output_launch_option");
  const output =
    family === "service" || family === "__service"
      ? outputLaunchOptions(opts)
      : ({ backend: "recording" } as const);
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
  if (family === "output" && action === "doctor") {
    for (const key of opts.keys())
      if (!["--receiver", "--json"].includes(key))
        throw new Error("invalid_output_doctor_option");
    return inspectOutputCapabilities(receiver);
  }
  if (family === "__wow-capture" && action === "run") {
    for (const key of opts.keys())
      if (key !== "--capture-helper")
        throw new Error("invalid_wow_capture_option");
    await runWowCaptureOwner(required(opts, "--capture-helper"));
    return undefined;
  }
  if (
    family === "wow" &&
    (action === "permission-status" || action === "request-permission")
  ) {
    for (const key of opts.keys())
      if (!["--capture-helper", "--json"].includes(key))
        throw new Error("invalid_wow_capture_option");
    return inspectWowCapturePermission(
      required(opts, "--capture-helper"),
      action === "request-permission",
    );
  }
  const raw = opts.get("--runtime-dir");
  const root = runtimeDirectory(
    typeof raw === "string" ? raw : join(homedir(), ".thumble-rewrite-runtime"),
  );
  if (family === "wow") {
    for (const key of opts.keys())
      if (!["--runtime-dir", "--receiver", "--source", "--json"].includes(key))
        throw new Error("invalid_wow_capture_option");
    const body =
      action === "capture-start"
        ? { command: "wow-capture-start", source: required(opts, "--source") }
        : { command: `wow-${action}` };
    if (action !== "capture-start" && opts.has("--source"))
      throw new Error("invalid_wow_capture_option");
    return requestWowCapture(
      readEndpoint(root, receiver),
      decodeWowCaptureCommand(body),
    );
  }
  if (family === "mcp") {
    if (action !== "serve") throw new Error("unsupported_mcp_command");
    for (const key of opts.keys())
      if (
        ![
          "--runtime-dir",
          "--receiver",
          "--allow-recorded-input",
          "--allow-configuration-write",
          "--allow-wow-capture",
        ].includes(key)
      )
        throw new Error("invalid_mcp_option");
    startMcp(
      root,
      receiver,
      opts.get("--allow-recorded-input") === true,
      opts.get("--allow-configuration-write") === true,
      opts.get("--allow-wow-capture") === true,
    );
    return undefined;
  }
  if (family === "identity") {
    if (action !== "initialize" && action !== "show")
      throw new Error("unsupported_identity_command");
    for (const key of opts.keys())
      if (!["--identity-dir", "--receiver", "--json"].includes(key))
        throw new Error("invalid_identity_option");
    const directory = required(opts, "--identity-dir");
    if (!isAbsolute(directory))
      throw new Error("identity_directory_must_be_absolute");
    return nativeIdentity(receiver, directory, action);
  }

  if (family === "__configuration" && action === "run") {
    for (const key of opts.keys())
      if (!["--runtime-dir", "--receiver"].includes(key))
        throw new Error("invalid_configuration_owner_option");
    await runConfigurationOwner(root, receiver);
    return undefined;
  }
  if (family === "__service" && action === "run") {
    const identityDirectory = opts.get("--identity-dir");
    if (
      identityDirectory !== undefined &&
      (typeof identityDirectory !== "string" || !isAbsolute(identityDirectory))
    )
      throw new Error("identity_directory_must_be_absolute");
    await serve(
      receiver,
      root,
      typeof identityDirectory === "string" ? identityDirectory : undefined,
      source ? [process.execPath, process.argv[1]!] : [process.execPath],
      typeof opts.get("--capture-helper") === "string"
        ? required(opts, "--capture-helper")
        : undefined,
      output,
    );
    return undefined;
  }
  if (family === "service" && action === "run") {
    const identityDirectory = opts.get("--identity-dir");
    if (
      identityDirectory !== undefined &&
      (typeof identityDirectory !== "string" || !isAbsolute(identityDirectory))
    )
      throw new Error("identity_directory_must_be_absolute");
    await serve(
      receiver,
      root,
      typeof identityDirectory === "string" ? identityDirectory : undefined,
      source ? [process.execPath, process.argv[1]!] : [process.execPath],
      typeof opts.get("--capture-helper") === "string"
        ? required(opts, "--capture-helper")
        : undefined,
      output,
    );
    return undefined;
  }
  if (family === "service" && action === "start") {
    secureDirectory(receiver, root);
    const identityDirectory = opts.get("--identity-dir");
    if (
      identityDirectory !== undefined &&
      (typeof identityDirectory !== "string" || !isAbsolute(identityDirectory))
    )
      throw new Error("identity_directory_must_be_absolute");
    const expectedIdentity =
      typeof identityDirectory === "string"
        ? nativeIdentity(receiver, identityDirectory, "show")
        : undefined;
    let running;
    try {
      running = await request(readEndpoint(root, receiver), {
        command: "status",
      });
    } catch {}
    if (running) {
      if (
        opts.has("--capture-helper") ||
        opts.has("--output") ||
        opts.has("--allow-physical-output")
      )
        throw new Error("service_launch_options_restart_required");
      if (expectedIdentity) {
        const pairing = await requestPairing(readEndpoint(root, receiver), {
          command: "pairing-status",
        });
        if (
          !pairing.transport?.persistentIdentity ||
          pairing.transport.certificatePin !== expectedIdentity.certificatePin
        )
          throw new Error("service_identity_configuration_mismatch");
      }
      return running;
    }
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
        ...(typeof identityDirectory === "string"
          ? ["--identity-dir", identityDirectory]
          : []),
        ...(opts.has("--capture-helper")
          ? ["--capture-helper", required(opts, "--capture-helper")]
          : []),
        ...(output.backend === "macos-hid"
          ? ["--output", "macos-hid", "--allow-physical-output"]
          : []),
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
  if (family === "pairing") {
    if (
      ![
        "open",
        "status",
        "list",
        "revoke",
        "cancel",
        "listen",
        "stop-listening",
      ].includes(action ?? "")
    )
      throw new Error("unsupported_pairing_command");
    if (
      (action === "open" || action === "listen") &&
      opts.get("--reveal-secret") !== true
    )
      throw new Error("pairing_secret_output_opt_in_required");
    if (action === "revoke")
      return requestPairing(readEndpoint(root, receiver), {
        command: "pairing-revoke",
        phoneId: required(opts, "--phone-id"),
      });
    if (action === "listen")
      return requestPairing(readEndpoint(root, receiver), {
        command: "pairing-listen",
        bindAddress: required(opts, "--bind-address"),
        advertiseHost: required(opts, "--advertise-host"),
      });
    return requestPairing(readEndpoint(root, receiver), {
      command: `pairing-${action}` as
        | "pairing-open"
        | "pairing-status"
        | "pairing-list"
        | "pairing-cancel"
        | "pairing-stop-listening",
    });
  }
  if (family === "configuration") {
    if (action === "validate-file") {
      for (const key of opts.keys())
        if (!["--file", "--json"].includes(key))
          throw new Error("invalid_configuration_option");
      return inspectConfigurationFile(required(opts, "--file"));
    }
    if (
      ["import-file", "import-status", "export-file", "export-status"].includes(
        action ?? "",
      )
    ) {
      const allowed = [
        "--runtime-dir",
        "--receiver",
        "--json",
        "--operation-id",
        "--expected-revision",
        "--expected-receiver-revision",
        "--expected-configuration-revision",
        "--expected-source-hash",
        ...(action !== "import-status" ? ["--file"] : []),
      ];
      for (const key of opts.keys())
        if (!allowed.includes(key))
          throw new Error("invalid_configuration_option");
      const command = decodeConfigurationCommand({
        command:
          action === "import-file"
            ? "configuration-import-file"
            : action === "import-status"
              ? "configuration-import-status"
              : action === "export-file"
                ? "configuration-export-file"
                : "configuration-export-status",
        operationId: required(opts, "--operation-id"),
        expectedRevision: required(opts, "--expected-revision"),
        expectedSourceHash: required(opts, "--expected-source-hash"),
        ...(action !== "import-status"
          ? { path: required(opts, "--file") }
          : {}),
      });
      return requestConfiguration(readEndpoint(root, receiver), command);
    }
    if (action === "initialize-starter") {
      const allowed = [
        "--runtime-dir",
        "--receiver",
        "--json",
        "--operation-id",
        "--expected-revision",
        "--profile-id",
        "--name",
      ];
      for (const key of opts.keys())
        if (!allowed.includes(key))
          throw new Error("invalid_configuration_option");
      const command = decodeConfigurationCommand({
        command: "configuration-initialize-starter",
        operationId: required(opts, "--operation-id"),
        expectedRevision: required(opts, "--expected-revision"),
        profileId: required(opts, "--profile-id"),
        name: required(opts, "--name"),
      });
      return requestConfiguration(readEndpoint(root, receiver), command);
    }
    if (action === "duplicate-profile") {
      const allowed = [
        "--runtime-dir",
        "--receiver",
        "--json",
        "--operation-id",
        "--expected-revision",
        "--expected-receiver-revision",
        "--expected-configuration-revision",
        "--profile-id",
        "--new-profile-id",
        "--name",
        "--select",
        "--keep-selection",
      ];
      for (const key of opts.keys())
        if (!allowed.includes(key))
          throw new Error("invalid_configuration_option");
      if (opts.has("--select") === opts.has("--keep-selection"))
        throw new Error("configuration_selection_required");
      const command = decodeConfigurationCommand({
        command: "configuration-duplicate-profile",
        operationId: required(opts, "--operation-id"),
        expectedRevision: required(opts, "--expected-revision"),
        profileId: required(opts, "--profile-id"),
        newProfileId: required(opts, "--new-profile-id"),
        name: required(opts, "--name"),
        select: opts.has("--select"),
      });
      return requestConfiguration(readEndpoint(root, receiver), command);
    }
    if (action === "select-profiles") {
      const allowed = [
        "--runtime-dir",
        "--receiver",
        "--json",
        "--operation-id",
        "--expected-revision",
        "--expected-receiver-revision",
        "--expected-configuration-revision",
        "--active-profile-id",
        "--default-profile-id",
      ];
      for (const key of opts.keys())
        if (!allowed.includes(key))
          throw new Error("invalid_configuration_option");
      const defaultId = required(opts, "--default-profile-id");
      const command = decodeConfigurationCommand({
        command: "configuration-select-profiles",
        operationId: required(opts, "--operation-id"),
        expectedRevision: required(opts, "--expected-revision"),
        activeProfileId: required(opts, "--active-profile-id"),
        defaultProfileId: defaultId === "none" ? null : defaultId,
      });
      return requestConfiguration(readEndpoint(root, receiver), command);
    }
    if (action !== "list" && action !== "rename-profile")
      throw new Error("unsupported_configuration_command");
    const allowed =
      action === "list"
        ? [
            "--runtime-dir",
            "--receiver",
            "--json",
            "--expected-revision",
            "--expected-receiver-revision",
            "--expected-configuration-revision",
            "--offset",
          ]
        : [
            "--runtime-dir",
            "--receiver",
            "--json",
            "--expected-revision",
            "--expected-receiver-revision",
            "--expected-configuration-revision",
            "--file",
            "--operation-id",
            "--profile-id",
            "--name",
          ];
    for (const key of opts.keys())
      if (!allowed.includes(key))
        throw new Error("invalid_configuration_option");
    const rawOffset = opts.get("--offset") ?? "0";
    if (
      action === "list" &&
      (typeof rawOffset !== "string" ||
        !/^(?:0|[1-9][0-9]{0,2})$/.test(rawOffset))
    )
      throw new Error("invalid_configuration_offset");
    const command = decodeConfigurationCommand(
      action === "list"
        ? {
            command: "configuration-list",
            expectedRevision: opts.get("--expected-revision") ?? null,
            offset: Number(rawOffset),
          }
        : {
            command: "configuration-rename-profile",
            operationId: required(opts, "--operation-id"),
            expectedRevision: required(opts, "--expected-revision"),
            profileId: required(opts, "--profile-id"),
            name: required(opts, "--name"),
          },
    );
    return requestConfiguration(readEndpoint(root, receiver), command);
  }
  if (
    family === "receiver" &&
    (action === "activate-saved" || action === "saved-status")
  ) {
    const allowed = new Set([
      "--runtime-dir",
      "--receiver",
      "--json",
      ...(action === "activate-saved"
        ? [
            "--expected-receiver-revision",
            "--expected-configuration-revision",
            "--expected-source-hash",
            "--profile-id",
          ]
        : []),
    ]);
    for (const key of opts.keys())
      if (!allowed.has(key)) throw new Error("invalid_saved_runtime_option");
    const command = decodeSavedRuntimeCommand(
      action === "saved-status"
        ? { command: "saved-binding-status" }
        : {
            command: "activate-saved",
            expectedReceiverRevision: required(
              opts,
              "--expected-receiver-revision",
            ),
            expectedConfigurationRevision: required(
              opts,
              "--expected-configuration-revision",
            ),
            expectedSourceHash: required(opts, "--expected-source-hash"),
            profileId: required(opts, "--profile-id"),
          },
    );
    return requestSavedRuntime(readEndpoint(root, receiver), command);
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
  if (arguments_[0] === "mcp") console.error(code);
  else console.log(JSON.stringify({ version: 1, ok: false, error: code }));
  process.exit(1);
}
