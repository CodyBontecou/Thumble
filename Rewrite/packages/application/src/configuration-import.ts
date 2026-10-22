import { LosslessJson } from "@thumble/contracts/json";
import {
  decodeConfigurationCommand,
  type ConfigurationImportFileCommand,
  type ConfigurationReply,
} from "@thumble/contracts/configuration";
import { OwnedAuthorityDocument } from "@thumble/domain/owned-authority";
import type { ResourceDigest } from "@thumble/domain/owned-configuration";
import {
  ConfigurationRevisionConflict,
  type ConfigurationRepository,
} from "./configuration-store.ts";
import type { ConfigurationAccess } from "./configuration-catalog.ts";

/** Intent identity excludes the locator path: the reviewed source hash identifies
 * the data, and a retry can recover a durable receipt after the file is removed. */
export function configurationImportIntent(
  command: Pick<
    ConfigurationImportFileCommand,
    "expectedRevision" | "expectedSourceHash"
  >,
): string {
  return JSON.stringify([
    "thumble-owned-import-v1",
    "replace-configuration",
    command.expectedRevision,
    command.expectedSourceHash,
  ]);
}
/** Explicit full replacement of saved data only. No migration, publication or
 * runtime activation. Hashes/functions/paths are resolved by the trusted owner. */
export class ConfigurationImportOperations {
  constructor(
    private readonly repository: ConfigurationRepository,
    private readonly ports: Readonly<{
      readFile: (path: string) => LosslessJson;
      digest: (payload: string) => string;
      sourceHash: (source: LosslessJson) => string;
      resourceHash: ResourceDigest;
    }>,
  ) {}
  execute(
    input: ConfigurationImportFileCommand,
    access: ConfigurationAccess,
  ): ConfigurationReply {
    const command = decodeConfigurationCommand(input);
    if (command.command !== "configuration-import-file")
      throw new Error("unsupported_configuration_command");
    if (!access.read || !access.write)
      throw new Error("configuration_access_denied");
    const payloadHash = this.ports.digest(configurationImportIntent(command));
    const previous = this.repository.receipt(command.operationId, payloadHash);
    if (previous)
      return Object.freeze({
        version: 1,
        kind: "import-committed",
        receipt: previous,
        replayed: true,
        validation: "owned-v5-structural",
        activationCompatibility: "not-evaluated",
      });
    try {
      const revision = this.repository.current()?.revision ?? "0";
      if (revision !== command.expectedRevision)
        throw new ConfigurationRevisionConflict(revision);
      const source = this.ports.readFile(command.path);
      if (this.ports.sourceHash(source) !== command.expectedSourceHash)
        throw new Error("configuration_source_changed");
      const preparation = OwnedAuthorityDocument.prepare(
        source,
        this.ports.resourceHash,
      );
      const result = this.repository.commit({
        operationId: command.operationId,
        payloadHash,
        expectedRevision: command.expectedRevision,
        source: preparation.document.source,
        affectedEntities: ["configuration"],
        assets: preparation.assets(),
      });
      return Object.freeze({
        version: 1,
        kind: "import-committed",
        ...result,
        validation: "owned-v5-structural",
        activationCompatibility: "not-evaluated",
      });
    } catch (error) {
      if (error instanceof ConfigurationRevisionConflict)
        return Object.freeze({
          version: 1,
          kind: "conflict",
          currentRevision: error.currentRevision,
        });
      throw error;
    }
  }
}
