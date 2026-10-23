import {
  decodePhonePresentationCommand,
  decodePhonePresentationResult,
  type PhonePresentationCommand,
  type PhonePresentationResult,
} from "@thumble/contracts/phone-presentation";
import {
  decodePhoneControlsQuery,
  phoneControlNumber,
  type PhoneControlsQuery,
} from "@thumble/contracts/phone-controls";
import {
  decodeControlMap,
  type ControlMap,
} from "@thumble/contracts/mobile-input";
import type { LosslessJson } from "@thumble/contracts/json";
import { OwnedAuthorityDocument } from "@thumble/domain/owned-authority";
import {
  OwnedConfigurationDocument,
  type ResourceDigest,
} from "@thumble/domain/owned-configuration";
import { projectSavedController } from "@thumble/domain/saved-controller-map";
import {
  projectSavedPresentation,
  type SavedPresentation,
} from "@thumble/domain/saved-presentation";
import { encodeResourceBase64 } from "@thumble/domain/owned-resources";
import type { ConfigurationRepository } from "./configuration-store.ts";
type Freshness = "observed" | "stale" | "not-evaluated";
type Baseline = {
  map: ControlMap;
  latest?: {
    revision: string;
    sourceHash: string;
    colorScheme: "light" | "dark";
    presentation: SavedPresentation;
  };
};
/** Server-minted successful-map cache, not caller-provided historical source. */
export class ConfigurationPhonePresentationOperations {
  private readonly baselines = new Map<string, Baseline>();
  constructor(
    private readonly repository: ConfigurationRepository,
    private readonly ports: Readonly<{
      sourceHash: (source: LosslessJson) => string;
      documentHash: (text: string) => string;
      resourceHash: ResourceDigest;
      readAsset: (hash: string) => Uint8Array;
      verifyIcon: (png: Uint8Array) => void;
      freshness: (
        profileId: string,
        revision: string,
        sourceHash: string,
      ) => Freshness;
    }>,
  ) {}
  private key(query: PhoneControlsQuery, configurationSha256: string): string {
    return JSON.stringify([
      query.authorityInstanceId,
      query.expectedConfigurationRevision,
      query.expectedSourceHash,
      query.profileId,
      query.generation,
      query.revision,
      query.viewportWidth,
      query.viewportHeight,
      configurationSha256,
    ]);
  }
  remember(
    input: PhoneControlsQuery,
    configurationSha256: string,
    inputMap: ControlMap,
  ): void {
    const query = decodePhoneControlsQuery(input),
      map = decodeControlMap(inputMap);
    if (
      !/^[a-f0-9]{64}$/.test(configurationSha256) ||
      map.generation !== query.generation ||
      map.revision !== query.revision
    )
      throw Error("presentation_baseline_invalid");
    const key = this.key(query, configurationSha256);
    this.baselines.delete(key);
    this.baselines.set(key, { map });
    while (this.baselines.size > 8)
      this.baselines.delete(this.baselines.keys().next().value!);
  }
  execute(input: PhonePresentationCommand): PhonePresentationResult {
    const command = decodePhonePresentationCommand(input);
    try {
      const key = this.key(command, command.configurationSha256),
        baseline = this.baselines.get(key);
      if (!baseline)
        return { kind: "error", error: "presentation_reactivation_required" };
      this.baselines.delete(key);
      this.baselines.set(key, baseline);
      const current = this.repository.current();
      if (!current)
        return { kind: "error", error: "presentation_reactivation_required" };
      if (this.ports.sourceHash(current.source) !== current.contentHash)
        throw Error("presentation_source_invalid");
      if (command.kind === "icon") {
        if (
          current.revision !== command.presentationRevision ||
          current.contentHash !== command.presentationSourceHash ||
          baseline.latest?.revision !== current.revision ||
          baseline.latest.sourceHash !== current.contentHash ||
          baseline.latest.colorScheme !== command.colorScheme
        )
          return { kind: "error", error: "presentation_stale" };
        const icon = baseline.latest.presentation.controls.find(
          (c) => c.id === command.controlId,
        )?.icon;
        if (!icon || icon.sha256 !== command.iconSHA256)
          return { kind: "error", error: "presentation_stale" };
        const { command: _, kind: __, ...echo } = command;
        return decodePhonePresentationResult(
          {
            ...echo,
            kind: "icon",
            byteCount: icon.bytes.length,
            pngBase64: encodeResourceBase64(icon.bytes),
          },
          command,
        );
      }
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
        return { kind: "error", error: "presentation_reactivation_required" };
      const projection = projectSavedController(
        { document, authorityRevision: current.revision },
        {
          profileId: command.profileId,
          authorityRevision: current.revision,
          sourceSha256: this.ports.documentHash(document.source.text()),
        },
        { generation: command.generation, revision: command.revision },
        {
          width: phoneControlNumber(command.viewportWidth),
          height: phoneControlNumber(command.viewportHeight),
        },
        this.ports.documentHash,
      );
      if (JSON.stringify(projection.map) !== JSON.stringify(baseline.map))
        return { kind: "error", error: "presentation_reactivation_required" };
      const presentation = projectSavedPresentation(
          document,
          command.profileId,
          command.colorScheme,
          projection.map,
          this.ports.resourceHash,
        ),
        verified = new Set<string>();
      for (const control of presentation.controls)
        if (control.icon && !verified.has(control.icon.sha256)) {
          this.ports.verifyIcon(control.icon.bytes.slice());
          verified.add(control.icon.sha256);
        }
      const { command: _, kind: __, ...echo } = command;
      const result: Record<string, string | number> = {
        ...echo,
        kind: "presentation",
        bank: "base",
        profileName: presentation.profileName,
        presentationRevision: current.revision,
        presentationSourceHash: current.contentHash,
        freshness: this.ports.freshness(
          command.profileId,
          current.revision,
          current.contentHash,
        ),
        controlCount: presentation.controls.length,
      };
      presentation.controls.forEach((control, i) => {
        const prefix = `control${i}`;
        result[prefix + "Id"] = control.id;
        result[prefix + "Label"] = control.label;
        if (control.icon) {
          result[prefix + "IconSHA256"] = control.icon.sha256;
          result[prefix + "IconByteCount"] = control.icon.bytes.length;
          result[prefix + "IconName"] = control.icon.name;
        }
      });
      const validated = decodePhonePresentationResult(result, command);
      baseline.latest = {
        revision: current.revision,
        sourceHash: current.contentHash,
        colorScheme: command.colorScheme,
        presentation,
      };
      return validated;
    } catch (error) {
      const code = error instanceof Error ? error.message : "";
      return {
        kind: "error",
        error: code.startsWith("saved_controller_")
          ? "presentation_reactivation_required"
          : code === "saved_presentation_unsupported" ||
              code === "presentation_icon_invalid"
            ? "presentation_unsupported_profile"
            : code.includes("too_large")
              ? "presentation_response_too_large"
              : "presentation_unavailable",
      };
    }
  }
}
