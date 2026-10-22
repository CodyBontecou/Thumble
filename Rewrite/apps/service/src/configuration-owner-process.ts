import { ConfigurationExportOperations } from "@thumble/application/configuration-export";
import { FileAssetStore } from "@thumble/storage/asset-files";
import { publishConfigurationFile } from "./configuration-export-files.ts";
import { ConfigurationImportOperations } from "@thumble/application/configuration-import";
import { readConfigurationFile } from "@thumble/client/local";
import { configurationSourceHash } from "@thumble/storage";
import { createHash } from "node:crypto";
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

/** Internal stdio endpoint. Only scoped commands cross this boundary, never raw
 * source, asset bytes, claimed receipts or caller-selected fingerprints. */
export async function runConfigurationOwner(
  directory: string,
  executable: string,
): Promise<void> {
  const repository = new SqliteConfigurationRepository(directory, executable);
  const operations = new ConfigurationCatalogOperations(
    repository,
    (text) => createHash("sha256").update(text, "utf8").digest("hex"),
    () => Date.now().toString(),
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
        if (Buffer.byteLength(line) > FRAME_BYTES)
          throw new Error("configuration_response_too_large");
        if (!process.stdout.write(line)) {
          blocked = true;
          process.stdin.pause();
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
      write({ version: 1, ready: "configuration", pid: process.pid });
    });
  } finally {
    repository.close();
  }
}
