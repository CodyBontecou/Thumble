import type { LosslessJson } from "@thumble/contracts/json";
import {
  decodeConfigurationCommand,
  type ConfigurationExportCommand,
  type ConfigurationReply,
} from "@thumble/contracts/configuration";
import { OwnedAuthorityDocument } from "@thumble/domain/owned-authority";
import {
  OwnedConfigurationDocument,
  type ResourceDigest,
} from "@thumble/domain/owned-configuration";
import type { ConfigurationRepository } from "./configuration-store.ts";
import type { ConfigurationAccess } from "./configuration-catalog.ts";

/** Export operation IDs are parent-session jobs, not durable authority receipts.
 * Destination is part of the intent: never reuse a pending job for another file. */
export function configurationExportIntent(
  command: ConfigurationExportCommand,
): string {
  return JSON.stringify([
    "thumble-owned-export-v1",
    command.expectedRevision,
    command.expectedSourceHash,
    command.path,
  ]);
}
export class ConfigurationExportOperations {
  constructor(
    private readonly repository: ConfigurationRepository,
    private readonly ports: Readonly<{
      encode: (text: string) => Uint8Array;
      readAsset: (sha256: string) => Uint8Array;
      resourceHash: ResourceDigest;
      sourceHash: (source: LosslessJson) => string;
      publish: (
        path: string,
        bytes: Uint8Array,
      ) => Readonly<{
        artifactHash: string;
        byteCount: number;
        replayed: boolean;
      }>;
    }>,
  ) {}
  execute(
    input: ConfigurationExportCommand,
    access: ConfigurationAccess,
  ): ConfigurationReply {
    const command = decodeConfigurationCommand(input);
    if (command.command !== "configuration-export-file")
      throw new Error("unsupported_configuration_command");
    // Writing a user-selected path requires the explicit local write capability,
    // although the configuration authority itself is never modified by export.
    if (!access.read || !access.write)
      throw new Error("configuration_access_denied");
    const current = this.repository.current();
    const revision = current?.revision ?? "0";
    if (revision !== command.expectedRevision)
      return Object.freeze({
        version: 1,
        kind: "conflict",
        currentRevision: revision,
      });
    if (!current) throw new Error("configuration_empty");
    if (
      current.contentHash !== command.expectedSourceHash ||
      this.ports.sourceHash(current.source) !== current.contentHash
    )
      throw new Error("configuration_source_changed");
    const document = OwnedAuthorityDocument.isAuthority(current.source)
      ? OwnedAuthorityDocument.read(current.source).materialize(
          this.ports.readAsset,
          this.ports.resourceHash,
        )
      : OwnedConfigurationDocument.read(
          current.source,
          this.ports.resourceHash,
        );
    const bytes = this.ports.encode(document.source.text());
    const published = this.ports.publish(command.path, bytes);
    if (
      published.byteCount !== bytes.length ||
      published.artifactHash !== this.ports.resourceHash(bytes.slice())
    )
      throw new Error("configuration_export_response_invalid");
    return Object.freeze({
      version: 1,
      kind: "exported",
      operationId: command.operationId,
      revision,
      sourceHash: current.contentHash,
      ...published,
    });
  }
}
