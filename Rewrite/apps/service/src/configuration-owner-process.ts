import { ConfigurationEditorReads } from "@thumble/application/configuration-editor-read";
import {
  decodeEditorReadEnvelope,
  decodeEditorLabelCommit,
} from "./editor-owner-envelope.ts";
import { ConfigurationPhonePresentationOperations } from "@thumble/application/configuration-phone-presentation";
import { decodeAnyPhonePresentationCommand } from "@thumble/contracts/phone-presentation";
import { verifyPresentationIcon } from "./presentation-icon.ts";
import { ConfigurationWowOperations } from "./configuration-wow.ts";
import { RetainedWowProfilePreparer } from "./wow-profile-preparer.ts";
import { WowCaptureSession } from "./wow-capture-session.ts";
import {
  NativeWowCaptureProvider,
  captureHelperPath,
} from "./wow-capture-provider.ts";
import { decodeWowAtlas } from "./wow-atlas-decoder.ts";
import { decodeWowCaptureCommand } from "@thumble/contracts/wow-capture-control";
import { decodeWowSyncCommand } from "@thumble/contracts/wow-sync-control";
import { lstatSync } from "node:fs";
import { ConfigurationPhoneControlsOperations } from "@thumble/application/configuration-phone-controls";
import { decodePhoneControlsCommand } from "@thumble/contracts/phone-controls";
import { ConfigurationSavedPinOperations } from "@thumble/application/configuration-saved-pin";
import { decodeSavedPinCommand } from "@thumble/contracts/saved-runtime";
import { ConfigurationExportOperations } from "@thumble/application/configuration-export";
import { FileAssetStore } from "@thumble/storage/asset-files";
import { publishConfigurationFile } from "./configuration-export-files.ts";
import { ConfigurationImportOperations } from "@thumble/application/configuration-import";
import { readConfigurationFile } from "@thumble/client/local";
import { configurationSourceHash } from "@thumble/storage";
import { createHash, randomUUID } from "node:crypto";
import { ConfigurationCatalogOperations } from "@thumble/application/configuration-catalog";
import { decodeConfigurationCommand } from "@thumble/contracts/configuration";
import {
  exact,
  identity,
  FRAME_BYTES,
  parseStrictJson,
  record,
} from "@thumble/contracts/receiver";
import { SqliteConfigurationRepository } from "@thumble/storage";

/** Internal stdio endpoint. No raw source, arbitrary asset reads, claimed
 * receipts or caller-selected fingerprints. Presentation icons are small,
 * independently verified replies scoped to a served map and current metadata. */
export async function runConfigurationOwner(
  directory: string,
  executable: string,
  helpers?: Readonly<{ capture?: string; profile?: string }>,
): Promise<void> {
  const authorize = (path: string | undefined) => {
    if (path === undefined) return undefined;
    if (lstatSync(path).isSymbolicLink()) throw new Error("wow_helper_invalid");
    return captureHelperPath(path);
  };
  const capturePath = authorize(helpers?.capture),
    profilePath = authorize(helpers?.profile);
  if (profilePath && !capturePath)
    throw new Error("wow_sync_capture_helper_required");
  const repository = new SqliteConfigurationRepository(directory, executable);
  // Only actual SQLite ownership may mint this immutable child lifetime.
  const ownerLifetimeId = randomUUID();
  const savedPins = new ConfigurationSavedPinOperations(
    repository,
    configurationSourceHash,
  );
  const operations = new ConfigurationCatalogOperations(
    repository,
    (text) => createHash("sha256").update(text, "utf8").digest("hex"),
    () => Date.now().toString(),
  );
  const editorReads = new ConfigurationEditorReads(repository, (text) =>
    createHash("sha256").update(text, "utf8").digest("hex"),
  );
  const imports = new ConfigurationImportOperations(repository, {
    readFile: readConfigurationFile,
    digest: (text) => createHash("sha256").update(text, "utf8").digest("hex"),
    sourceHash: configurationSourceHash,
    resourceHash: (bytes) => createHash("sha256").update(bytes).digest("hex"),
  });
  const assets = new FileAssetStore(directory, executable);
  const exports = new ConfigurationExportOperations(repository, {
    encode: (text) => Buffer.from(text, "utf8"),
    readAsset: (hash) => assets.read(hash),
    sourceHash: configurationSourceHash,
    resourceHash: (bytes) => createHash("sha256").update(bytes).digest("hex"),
    publish: (path, bytes) => publishConfigurationFile(executable, path, bytes),
  });
  let emit: (capture: unknown, sync: unknown) => void = () => {};
  let monitor: ReturnType<typeof setInterval> | undefined;
  let lastEvent = "";
  const providers = new Set<NativeWowCaptureProvider>();
  const capture = capturePath
    ? new WowCaptureSession({
        clock: () => Math.floor(performance.now()),
        schedule: (delay, callback) => {
          const timer = setTimeout(callback, delay);
          return () => clearTimeout(timer);
        },
        create: () => {
          const provider = new NativeWowCaptureProvider(
            capturePath,
            "--capture",
            undefined,
            () => capture!.providerUnavailable(),
          );
          providers.add(provider);
          provider.child.once("close", () => providers.delete(provider));
          return provider;
        },
        decodeAtlas: decodeWowAtlas,
      })
    : undefined;
  const wow = new ConfigurationWowOperations({
    repository,
    ...(capture ? { capture } : {}),
    ...(profilePath
      ? { preparer: new RetainedWowProfilePreparer(profilePath) }
      : {}),
    readAsset: (hash) => assets.read(hash),
    publish: (capture, sync) => emit(capture, sync),
  });
  const presentations = new ConfigurationPhonePresentationOperations(
    repository,
    {
      sourceHash: configurationSourceHash,
      documentHash: (text) =>
        createHash("sha256").update(text, "utf8").digest("hex"),
      resourceHash: (bytes) => createHash("sha256").update(bytes).digest("hex"),
      readAsset: (hash) => assets.read(hash),
      verifyIcon: verifyPresentationIcon,
      freshness: (profile, revision, hash) =>
        wow.presentationFreshness(profile, revision, hash),
    },
  );
  const phoneControls = new ConfigurationPhoneControlsOperations(repository, {
    sourceHash: configurationSourceHash,
    documentHash: (text) =>
      createHash("sha256").update(text, "utf8").digest("hex"),
    resourceHash: (bytes) => createHash("sha256").update(bytes).digest("hex"),
    readAsset: (hash) => assets.read(hash),
    served: (query, hash, map) => presentations.remember(query, hash, map),
  });
  try {
    await new Promise<void>((resolve, reject) => {
      let buffer = Buffer.alloc(0),
        ended = false,
        blocked = false;
      const finish = (error?: Error) => {
        if (ended) return;
        ended = true;
        process.stdin.pause();
        process.stdin.removeAllListeners("data");
        process.stdin.removeAllListeners("end");
        process.stdin.removeAllListeners("error");
        process.stdout.removeListener("error", outputFailure);
        process.stdout.removeListener("drain", resume);
        process.removeListener("SIGTERM", terminate);
        process.removeListener("SIGINT", terminate);
        if (error) reject(error);
        else resolve();
      };
      const outputFailure = () =>
        finish(new Error("configuration_output_failed"));
      const terminate = () => finish(new Error("configuration_owner_stopped"));
      const resume = () => {
        if (ended) return;
        blocked = false;
        pump();
        if (!blocked && !ended) process.stdin.resume();
      };
      const write = (value: unknown) => {
        const line = JSON.stringify(value) + "\n";
        if (
          Buffer.byteLength(line) > FRAME_BYTES ||
          process.stdout.writableLength > FRAME_BYTES * 2
        )
          throw new Error("configuration_response_too_large");
        if (!process.stdout.write(line)) {
          blocked = true;
          process.stdin.pause();
        }
      };
      emit = (capture, sync) => {
        const current = JSON.stringify([capture, sync]);
        if (current === lastEvent) return;
        lastEvent = current;
        if (!ended) {
          try {
            write({ version: 1, event: "wow-state", capture, sync });
          } catch {
            finish(new Error("configuration_output_failed"));
          }
        }
      };
      process.stdout.on("error", outputFailure);
      process.stdout.on("drain", resume);
      process.on("SIGTERM", terminate);
      process.on("SIGINT", terminate);
      process.stdin.on("error", () =>
        finish(new Error("configuration_input_failed")),
      );
      process.stdin.on("end", () =>
        finish(
          buffer.length
            ? new Error("configuration_frame_incomplete")
            : undefined,
        ),
      );
      process.stdin.on("data", (chunk: Buffer) => {
        if (ended) return;
        if (buffer.length + chunk.length > FRAME_BYTES * 16) {
          finish(new Error("configuration_buffer_full"));
          return;
        }
        buffer = Buffer.concat([buffer, chunk]);
        pump();
      });
      function pump(): void {
        for (
          let newline;
          !ended && !blocked && (newline = buffer.indexOf(10)) >= 0;

        ) {
          if (newline + 1 > FRAME_BYTES) {
            finish(new Error("configuration_frame_too_large"));
            return;
          }
          const frame = buffer.subarray(0, newline);
          buffer = buffer.subarray(newline + 1);
          let requestId: string;
          let body: unknown;
          try {
            const value = record(
              parseStrictJson(
                new TextDecoder("utf-8", { fatal: true }).decode(frame),
              ),
            );
            exact(value, ["version", "requestId", "body"]);
            if (value.version !== 1)
              throw new Error("configuration_protocol_invalid");
            requestId = identity(value.requestId);
            body = value.body;
          } catch {
            finish(new Error("configuration_protocol_invalid"));
            return;
          }
          try {
            const operation = record(body).command;
            if (
              typeof operation === "string" &&
              operation.startsWith("wow-capture-")
            ) {
              void wow.capture(decodeWowCaptureCommand(body)).then(
                (result) => {
                  if (!ended)
                    write({ version: 1, requestId, ok: true, result });
                },
                () => {
                  if (!ended)
                    write({
                      version: 1,
                      requestId,
                      ok: false,
                      error: "wow_capture_unavailable",
                    });
                },
              );
              continue;
            }
            if (
              typeof operation === "string" &&
              (operation === "wow-refresh" || operation.startsWith("wow-sync-"))
            ) {
              const result = wow.execute(decodeWowSyncCommand(body));
              write({ version: 1, requestId, ok: true, result });
              continue;
            }
            if (
              wow.busy &&
              operation !== "configuration-list" &&
              operation !== "configuration-phone-controls" &&
              operation !== "configuration-phone-presentation" &&
              operation !== "configuration-saved-pin"
            )
              throw new Error("configuration_owner_busy");
            if (operation === "editor-read") {
              const envelope = decodeEditorReadEnvelope(body);
              if (envelope.ownerLifetimeId !== ownerLifetimeId)
                throw new Error("editor_owner_lifetime_mismatch");
              const outcome = editorReads.execute(envelope.query, {
                read: true,
                write: false,
              });
              write({
                version: 1,
                requestId,
                ok: true,
                result: { envelope, outcome },
              });
              continue;
            }
            if (operation === "editor-label-commit") {
              const envelope = decodeEditorLabelCommit(body);
              if (envelope.ownerLifetimeId !== ownerLifetimeId)
                throw new Error("editor_owner_lifetime_mismatch");
              const outcome = operations.execute(envelope.intent, {
                read: true,
                write: true,
              });
              write({
                version: 1,
                requestId,
                ok: true,
                result: { envelope, outcome },
              });
              continue;
            }
            if (operation === "configuration-phone-presentation") {
              const result = presentations.execute(
                decodeAnyPhonePresentationCommand(body),
              );
              write({ version: 1, requestId, ok: true, result });
              continue;
            }
            if (operation === "configuration-phone-controls") {
              const result = phoneControls.execute(
                decodePhoneControlsCommand(body),
              );
              write({ version: 1, requestId, ok: true, result });
              continue;
            }
            if (record(body).command === "configuration-saved-pin") {
              const result = savedPins.execute(decodeSavedPinCommand(body));
              write({ version: 1, requestId, ok: true, result });
              continue;
            }
            const command = decodeConfigurationCommand(body);
            const result =
              command.command === "configuration-import-file"
                ? imports.execute(command, { read: true, write: true })
                : command.command === "configuration-export-file"
                  ? exports.execute(command, { read: true, write: true })
                  : operations.execute(command, { read: true, write: true });
            write({ version: 1, requestId, ok: true, result });
          } catch (error) {
            const code =
              error instanceof Error && /^[a-z_]{1,100}$/.test(error.message)
                ? error.message
                : "configuration_operation_failed";
            try {
              write({ version: 1, requestId, ok: false, error: code });
            } catch {
              finish(new Error("configuration_output_failed"));
              return;
            }
          }
        }
        if (!blocked && buffer.length > FRAME_BYTES)
          finish(new Error("configuration_frame_too_large"));
      }
      write({
        version: 1,
        ready: "configuration",
        pid: process.pid,
        ownerLifetimeId,
      });
      if (capturePath) emit(wow.captureStatus(), wow.status());
      if (capturePath)
        monitor = setInterval(
          () => emit(wow.captureStatus(), wow.status()),
          100,
        );
    });
  } finally {
    if (monitor) clearInterval(monitor);
    emit = () => {};
    await wow.close();
    for (const provider of providers) void provider.stop();
    repository.close();
  }
}
