import {
  decodeSavedPinCommand,
  type SavedPinCommand,
  type SavedConfigurationPin,
} from "@thumble/contracts/saved-runtime";
import { ConfigurationCatalog } from "@thumble/domain/configuration-catalog";
import { OwnedAuthorityDocument } from "@thumble/domain/owned-authority";
import type { LosslessJson } from "@thumble/contracts/json";
import type { ConfigurationRepository } from "./configuration-store.ts";
/** Read-only CAS at the sole writer. No source/resources cross the child boundary. */
export class ConfigurationSavedPinOperations {
  constructor(
    private readonly repository: ConfigurationRepository,
    private readonly digest: (source: LosslessJson) => string,
  ) {}
  execute(input: SavedPinCommand): SavedConfigurationPin {
    const command = decodeSavedPinCommand(input),
      current = this.repository.current();
    if (!current) throw new Error("configuration_empty");
    if (current.revision !== command.expectedRevision)
      throw new Error("configuration_revision_conflict");
    if (
      current.contentHash !== command.expectedSourceHash ||
      this.digest(current.source) !== current.contentHash
    )
      throw new Error("configuration_source_changed");
    const catalog = OwnedAuthorityDocument.isAuthority(current.source)
      ? OwnedAuthorityDocument.read(current.source).catalog
      : ConfigurationCatalog.read(current.source);
    if (catalog.activeProfileID !== command.profileId)
      throw new Error("saved_profile_not_selected");
    return Object.freeze({
      configurationRevision: current.revision,
      sourceHash: current.contentHash,
      profileId: catalog.activeProfileID,
    });
  }
}
