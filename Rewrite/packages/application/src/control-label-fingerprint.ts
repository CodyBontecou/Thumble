import {
  decodeConfigurationSetControlLabelCommand,
  type ConfigurationSetControlLabelCommand,
} from "@thumble/contracts/control-label";

/** Shared by writes and non-mutating reconciliation; operation identity is the receipt key. */
export function controlLabelFingerprint(
  input: ConfigurationSetControlLabelCommand,
  digest: (payload: string) => string,
): string {
  const command = decodeConfigurationSetControlLabelCommand(input);
  return digest(
    JSON.stringify([
      "thumble-catalog-operation-v1",
      command.command,
      command.expectedRevision,
      command.profileId,
      command.controlId,
      command.label,
    ]),
  );
}
