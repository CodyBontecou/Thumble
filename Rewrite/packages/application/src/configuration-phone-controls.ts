import {
  decodePhoneControlsCommand,
  phoneControlNumber,
  projectPhoneControlsMap,
  type PhoneControlsCommand,
  type PhoneControlsResult,
} from "@thumble/contracts/phone-controls";
import { OwnedAuthorityDocument } from "@thumble/domain/owned-authority";
import {
  OwnedConfigurationDocument,
  type ResourceDigest,
} from "@thumble/domain/owned-configuration";
import { projectSavedController } from "@thumble/domain/saved-controller-map";
import type { LosslessJson } from "@thumble/contracts/json";
import type { ConfigurationRepository } from "./configuration-store.ts";
/** Read-only snapshot projection in the sole configuration child, never heartbeat IO. */
export class ConfigurationPhoneControlsOperations {
  constructor(
    private readonly repository: ConfigurationRepository,
    private readonly ports: Readonly<{
      sourceHash: (source: LosslessJson) => string;
      documentHash: (text: string) => string;
      resourceHash: ResourceDigest;
      readAsset: (hash: string) => Uint8Array;
    }>,
  ) {}
  execute(input: PhoneControlsCommand): PhoneControlsResult {
    const command = decodePhoneControlsCommand(input);
    try {
      const current = this.repository.current();
      if (
        !current ||
        current.revision !== command.expectedConfigurationRevision ||
        current.contentHash !== command.expectedSourceHash
      )
        return { kind: "error", error: "saved_map_reactivation_required" };
      if (this.ports.sourceHash(current.source) !== current.contentHash)
        return { kind: "error", error: "saved_map_unavailable" };
      const document = OwnedAuthorityDocument.isAuthority(current.source)
        ? OwnedAuthorityDocument.read(current.source).materialize(
            this.ports.readAsset,
            this.ports.resourceHash,
          )
        : OwnedConfigurationDocument.read(
            current.source,
            this.ports.resourceHash,
          );
      if (document.catalog.activeProfileID !== command.profileId)
        return { kind: "error", error: "saved_map_reactivation_required" };
      const configurationSha256 = this.ports.documentHash(
        document.source.text(),
      );
      const projection = projectSavedController(
        { document, authorityRevision: current.revision },
        {
          profileId: command.profileId,
          authorityRevision: current.revision,
          sourceSha256: configurationSha256,
        },
        { generation: command.generation, revision: command.revision },
        {
          width: phoneControlNumber(command.viewportWidth),
          height: phoneControlNumber(command.viewportHeight),
        },
        this.ports.documentHash,
      );
      return projectPhoneControlsMap(
        command,
        configurationSha256,
        projection.map,
      );
    } catch (error) {
      const code = error instanceof Error ? error.message : "";
      return {
        kind: "error",
        error:
          code === "phone_controls_response_too_large"
            ? "saved_map_response_too_large"
            : code.startsWith("saved_controller_")
              ? "saved_map_unsupported_profile"
              : "saved_map_unavailable",
      };
    }
  }
}
