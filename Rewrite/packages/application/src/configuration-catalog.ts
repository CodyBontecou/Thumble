import { starterConfiguration } from "@thumble/domain/starter-configuration";
import { OwnedAuthorityDocument } from "@thumble/domain/owned-authority";
import {
  CONFIGURATION_PAGE_SIZE,
  decodeConfigurationCommand,
  type ConfigurationCommand,
  type ConfigurationReply,
} from "@thumble/contracts/configuration";
import { counter } from "@thumble/contracts/receiver";
import { ConfigurationCatalog } from "@thumble/domain/configuration-catalog";
import {
  ConfigurationRevisionConflict,
  type ConfigurationRepository,
} from "./configuration-store.ts";

export type ConfigurationAccess = Readonly<{ read: boolean; write: boolean }>;
/** Saved catalog operations and explicit empty-authority initialization.
 * Catalog admission never grants document/runtime validity.
 * Capabilities and ports come from the authenticated owner, never command fields. */
export class ConfigurationCatalogOperations {
  constructor(
    private readonly repository: ConfigurationRepository,
    private readonly digest: (canonicalPayload: string) => string,
    private readonly now: () => string,
  ) {}
  execute(
    input: ConfigurationCommand,
    access: ConfigurationAccess,
  ): ConfigurationReply {
    const command = decodeConfigurationCommand(input);
    if (
      command.command === "configuration-import-file" ||
      command.command === "configuration-import-status" ||
      command.command === "configuration-export-file" ||
      command.command === "configuration-export-status"
    )
      throw new Error("unsupported_configuration_command");
    if (
      !access.read ||
      (command.command !== "configuration-list" && !access.write)
    )
      throw new Error("configuration_access_denied");
    try {
      return this.apply(command);
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
  private apply(
    command: Exclude<
      ConfigurationCommand,
      {
        command:
          | "configuration-import-file"
          | "configuration-import-status"
          | "configuration-export-file"
          | "configuration-export-status";
      }
    >,
  ): ConfigurationReply {
    // A replay precedes both current-source decoding and the clock. The receipt
    // belongs to the original operation even after other edits or a restart.
    const payloadHash =
      command.command === "configuration-list"
        ? undefined
        : this.digest(
            JSON.stringify([
              "thumble-catalog-operation-v1",
              command.command,
              command.expectedRevision,
              ...(command.command === "configuration-rename-profile"
                ? [command.profileId, command.name]
                : command.command === "configuration-initialize-starter"
                  ? ["starter-v1", command.profileId, command.name]
                  : command.command === "configuration-select-profiles"
                    ? [command.activeProfileId, command.defaultProfileId]
                    : [
                        command.profileId,
                        command.newProfileId,
                        command.name,
                        command.select,
                      ]),
            ]),
          );
    if (command.command !== "configuration-list") {
      const previous = this.repository.receipt(
        command.operationId,
        payloadHash!,
      );
      if (previous)
        return Object.freeze({
          version: 1,
          kind: "committed",
          receipt: previous,
          replayed: true,
        });
    }
    const current = this.repository.current(),
      revision = current?.revision ?? "0";
    if (
      command.expectedRevision !== null &&
      command.expectedRevision !== revision
    )
      throw new ConfigurationRevisionConflict(revision);
    if (command.command === "configuration-list") {
      if (!current) {
        if (command.offset !== 0)
          throw new Error("configuration_offset_invalid");
        return Object.freeze({
          version: 1,
          kind: "catalog",
          revision,
          contentHash: null,
          profiles: Object.freeze([]),
          activeProfileId: null,
          defaultProfileId: null,
          nextOffset: null,
        });
      }
      const authority = OwnedAuthorityDocument.isAuthority(current.source)
        ? OwnedAuthorityDocument.read(current.source)
        : undefined;
      const catalog =
        authority?.catalog ?? ConfigurationCatalog.read(current.source);
      if (command.offset >= catalog.profiles.length)
        throw new Error("configuration_offset_invalid");
      const profiles = Object.freeze(
        catalog.profiles.slice(
          command.offset,
          command.offset + CONFIGURATION_PAGE_SIZE,
        ),
      );
      const next = command.offset + profiles.length;
      return Object.freeze({
        version: 1,
        kind: "catalog",
        revision,
        contentHash: current.contentHash,
        profiles,
        activeProfileId: catalog.activeProfileID,
        defaultProfileId: catalog.defaultProfileID,
        nextOffset: next < catalog.profiles.length ? next : null,
      });
    }
    if (command.command === "configuration-initialize-starter") {
      // Revision zero is accepted only without a current source. Generic commit
      // still performs the durable CAS, so a concurrent writer cannot be replaced.
      if (current) throw new ConfigurationRevisionConflict(revision);
      const source = starterConfiguration(
        command.profileId,
        command.name,
        this.now(),
      );
      const prepared = OwnedAuthorityDocument.prepare(source, () => {
        throw new Error("configuration_starter_invalid");
      });
      const result = this.repository.commit({
        operationId: command.operationId,
        payloadHash: payloadHash!,
        expectedRevision: "0",
        source: prepared.document.source,
        affectedEntities: ["configuration", command.profileId],
      });
      return Object.freeze({ version: 1, kind: "committed", ...result });
    }
    if (!current) throw new Error("configuration_not_initialized");
    const authority = OwnedAuthorityDocument.isAuthority(current.source)
      ? OwnedAuthorityDocument.read(current.source)
      : undefined;
    const catalog =
      authority?.catalog ?? ConfigurationCatalog.read(current.source);
    let candidate;
    if (command.command === "configuration-select-profiles") {
      candidate = authority
        ? authority.selectProfiles(
            command.activeProfileId,
            command.defaultProfileId,
          ).source
        : catalog.selectProfiles(
            command.activeProfileId,
            command.defaultProfileId,
          ).source;
    } else {
      const profile = catalog.profiles.find((p) => p.id === command.profileId);
      if (!profile) throw new Error("profile_not_found");
      const clock = counter(this.now());
      if (BigInt(clock) > 9223372036854775807n)
        throw new Error("configuration_clock_invalid");
      if (command.command === "configuration-duplicate-profile") {
        candidate = authority
          ? authority.duplicateProfile(
              command.profileId,
              command.newProfileId,
              command.name,
              clock,
              command.select,
            ).source
          : catalog.duplicateProfile(
              command.profileId,
              command.newProfileId,
              command.name,
              clock,
              command.select,
            ).source;
      } else {
        const updatedAt =
          BigInt(clock) > BigInt(profile.updatedAt) ? clock : profile.updatedAt;
        candidate = authority
          ? authority.renameProfile(command.profileId, command.name, updatedAt)
              .source
          : catalog.renameProfile(command.profileId, command.name, updatedAt)
              .source;
      }
    }
    // Even a no-op commits a receipt/revision: retry semantics do not depend
    // on current names/selections, clocks or intervening configuration edits.
    const result = this.repository.commit({
      operationId: command.operationId,
      payloadHash: payloadHash!,
      expectedRevision: command.expectedRevision,
      source: candidate,
      affectedEntities:
        command.command === "configuration-select-profiles"
          ? ["configuration"]
          : command.command === "configuration-duplicate-profile"
            ? ["configuration", command.newProfileId]
            : [command.profileId],
    });
    return Object.freeze({ version: 1, kind: "committed", ...result });
  }
}
