import type { LosslessJson } from "@thumble/contracts/json";

export type ConfigurationSource = Readonly<{
  revision: string;
  contentHash: string;
  source: LosslessJson;
}>;
import type { ConfigurationReceipt } from "@thumble/contracts/configuration";
export type { ConfigurationReceipt } from "@thumble/contracts/configuration";
export type ConfigurationCommit = Readonly<{
  operationId: string;
  payloadHash: string;
  expectedRevision: string;
  source: LosslessJson;
  affectedEntities: readonly string[];
}>;
/** Trusted use cases validate documents/capabilities and derive payloadHash server-side.
 * Never expose this generic source port or caller-supplied fingerprints as a wire operation. */
export interface ConfigurationRepository {
  current(): ConfigurationSource | undefined;
  receipt(
    operationId: string,
    payloadHash: string,
  ): ConfigurationReceipt | undefined;
  commit(
    command: ConfigurationCommit,
  ): Readonly<{ receipt: ConfigurationReceipt; replayed: boolean }>;
}
export class ConfigurationRevisionConflict extends Error {
  constructor(readonly currentRevision: string) {
    super("configuration_revision_conflict");
  }
}
