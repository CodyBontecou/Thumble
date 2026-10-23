import { LosslessJson } from "@thumble/contracts/json";
import {
  OwnedConfigurationDocument,
  type ResourceDigest,
} from "@thumble/domain/owned-configuration";
export type ConfigurationValidation = Readonly<{
  version: 1;
  documentVersion: 5;
  validation: "owned-v5-structural";
  profileCount: number;
  elementCount: number;
  appearanceStateCount: number;
  resourceCount: number;
  resourceBytes: number;
  contentHash: string;
  hashCanonicalization: string;
  activationCompatibility: "not-evaluated";
}>;
/** Read-only preparation. No authority repository, receipt, migration or output port. */
export function validateOwnedConfiguration(
  source: LosslessJson,
  digests: Readonly<{
    resource: ResourceDigest;
    source: (value: LosslessJson) => string;
  }>,
): ConfigurationValidation {
  const document = OwnedConfigurationDocument.read(source, digests.resource);
  const contentHash = digests.source(source);
  if (!/^[0-9a-f]{64}$/.test(contentHash))
    throw new Error("configuration_hash_invalid");
  let elementCount = 0,
    appearanceStateCount = 0,
    resourceCount = 0,
    resourceBytes = 0;
  for (const profile of document.profiles) {
    elementCount += profile.elements.length;
    appearanceStateCount += profile.appearanceStates.length;
    resourceCount += profile.resources?.count ?? 0;
    resourceBytes += profile.resources?.byteCount ?? 0;
  }
  return Object.freeze({
    version: 1,
    documentVersion: 5,
    validation: "owned-v5-structural",
    profileCount: document.profiles.length,
    elementCount,
    appearanceStateCount,
    resourceCount,
    resourceBytes,
    contentHash,
    hashCanonicalization: LosslessJson.canonicalization,
    activationCompatibility: "not-evaluated",
  });
}
