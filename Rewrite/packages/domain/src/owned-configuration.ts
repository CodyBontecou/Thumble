import type { LosslessJson } from "@thumble/contracts/json";
import { ConfigurationCatalog } from "./configuration-catalog.ts";
import { validateOwnedBindingMaps } from "./owned-bindings.ts";
import { readOwnedProfile, type OwnedProfile } from "./owned-profile.ts";
import type { ResourceDigest } from "./owned-resources.ts";
import { uuid } from "./owned-json.ts";
export type {
  OwnedProfile,
  OwnedElement,
  OwnedControlKind,
  OwnedInputPart,
  OwnedPresentation,
  OwnedInputSettings,
  OwnedJoystickSettings,
  OwnedTriggerSettings,
  OwnedTrackpadSettings,
} from "./owned-profile.ts";
export type { ResourceDigest } from "./owned-resources.ts";
/** Immutable exact-source document. This codec never migrates or activates authority. */
export class OwnedConfigurationDocument {
  readonly source: LosslessJson;
  readonly catalog: ConfigurationCatalog;
  readonly profiles: readonly OwnedProfile[];
  readonly #byId: ReadonlyMap<string, OwnedProfile>;
  private constructor(source: LosslessJson, digest: ResourceDigest) {
    this.source = source;
    this.catalog = ConfigurationCatalog.read(source);
    const profiles = this.catalog.profiles.map((_, index) =>
      readOwnedProfile(source.get(`/profiles/${index}`)!, digest),
    );
    this.profiles = Object.freeze(profiles);
    const declarations = new Map(
      this.catalog.profiles.map(
        (summary, index) =>
          [
            summary.id,
            new Set(profiles[index]!.elements.map((e) => e.id)),
          ] as const,
      ),
    );
    validateOwnedBindingMaps(
      source,
      declarations,
      this.catalog.activeProfileID,
    );
    this.#byId = new Map(
      this.catalog.profiles.map(
        (summary, index) => [summary.id, profiles[index]!] as const,
      ),
    );
    Object.freeze(this);
  }
  static read(
    source: LosslessJson,
    digest: ResourceDigest,
  ): OwnedConfigurationDocument {
    return new OwnedConfigurationDocument(source, digest);
  }
  profile(id: string): OwnedProfile {
    const profile = this.#byId.get(uuid(id));
    if (!profile) throw new Error("profile_not_found");
    return profile;
  }
}
Object.freeze(OwnedConfigurationDocument.prototype);

export type {
  OwnedKeyBinding,
  OwnedKeyStroke,
  OwnedOutput,
} from "./owned-bindings.ts";
